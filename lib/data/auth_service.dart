import 'package:drift/drift.dart';

import '../config/app_config.dart';
import '../core/pin_hasher.dart';
import 'database.dart';
import 'tables.dart';

class PinPolicyException implements Exception {
  PinPolicyException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A staff-management rule was broken. The message is shown to the user.
class StaffRuleException implements Exception {
  StaffRuleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Staff accounts and PIN sign-in.
class AuthService {
  AuthService(
    this._db, {
    this._hasher = const PinHasher(),
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final PinHasher _hasher;
  final DateTime Function() _now;

  final Map<int, int> _failures = {};
  final Map<int, DateTime> _lockedUntil = {};

  Future<bool> hasAnyUser() async =>
      (await (_db.select(_db.users)..limit(1)).get()).isNotEmpty;

  Future<List<User>> activeUsers() =>
      (_db.select(_db.users)
            ..where((u) => u.active.equals(true))
            ..orderBy([(u) => OrderingTerm.asc(u.displayName)]))
          .get();

  /// Validates a PIN against the shop policy. Returns an error message in
  /// plain words, or null when the PIN is acceptable.
  static String? pinProblem(String pin) {
    if (!RegExp(r'^\d+$').hasMatch(pin)) return 'Use digits only.';
    if (pin.length < AppConfig.pinMinLength ||
        pin.length > AppConfig.pinMaxLength) {
      return 'Use ${AppConfig.pinMinLength} to ${AppConfig.pinMaxLength} digits.';
    }
    if (RegExp(r'^(\d)\1+$').hasMatch(pin)) return 'Do not repeat one digit.';
    return null;
  }

  Future<User> createUser({
    required String displayName,
    required Role role,
    required String pin,
  }) async {
    final name = displayName.trim();
    if (name.length < 2) throw PinPolicyException('Enter the full name.');
    final problem = pinProblem(pin);
    if (problem != null) throw PinPolicyException(problem);

    final salt = _hasher.newSalt();
    final id = await _db
        .into(_db.users)
        .insert(
          UsersCompanion.insert(
            username: await _uniqueUsername(name),
            displayName: name,
            role: role,
            secretHash: _hasher.hash(pin, salt),
            secretSalt: salt,
          ),
        );
    return (_db.select(_db.users)..where((u) => u.id.equals(id))).getSingle();
  }

  Future<String> _uniqueUsername(String name) async {
    final base = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '.')
        .replaceAll(RegExp(r'^\.|\.$'), '');
    var candidate = base.length < 2 ? 'user' : base;
    var n = 1;
    while ((await (_db.select(
      _db.users,
    )..where((u) => u.username.equals(candidate))).get()).isNotEmpty) {
      n++;
      candidate = '$base.$n';
    }
    return candidate;
  }

  // ---- Staff management -------------------------------------------------

  /// Everyone, active first, then by name.
  Future<List<User>> allUsers() =>
      (_db.select(_db.users)..orderBy([
            (u) => OrderingTerm.desc(u.active),
            (u) => OrderingTerm.asc(u.displayName),
          ]))
          .get();

  Future<User> _require(int id) async {
    final u = await (_db.select(
      _db.users,
    )..where((x) => x.id.equals(id))).getSingleOrNull();
    if (u == null) throw StaffRuleException('That account no longer exists.');
    return u;
  }

  Future<int> _activeOwnerCount() async {
    final owners =
        await (_db.select(_db.users)..where(
              (u) => u.active.equals(true) & u.role.equalsValue(Role.owner),
            ))
            .get();
    return owners.length;
  }

  /// Changes the name and role. The shop must always keep one active owner.
  Future<void> updateUser(
    int id, {
    required String displayName,
    required Role role,
  }) async {
    final name = displayName.trim();
    if (name.length < 2) throw StaffRuleException('Enter the full name.');
    final user = await _require(id);
    final losesOwner = user.role == Role.owner && role != Role.owner;
    if (losesOwner && user.active && await _activeOwnerCount() <= 1) {
      throw StaffRuleException(
        'This is the only owner. Make someone else an owner first.',
      );
    }
    await (_db.update(_db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(displayName: Value(name), role: Value(role)),
    );
  }

  /// Owner sets a new PIN for someone who forgot theirs. Also lifts any lockout.
  Future<void> resetPin(int id, String newPin) async {
    final problem = pinProblem(newPin);
    if (problem != null) throw PinPolicyException(problem);
    await _require(id);
    await _storePin(id, newPin);
    _failures.remove(id);
    _lockedUntil.remove(id);
  }

  /// A user changes their own PIN; the current PIN is required.
  Future<void> changeOwnPin(
    int id, {
    required String currentPin,
    required String newPin,
  }) async {
    final user = await _require(id);
    if (!_hasher.verify(currentPin, user.secretSalt, user.secretHash)) {
      throw StaffRuleException('Your current PIN is not right.');
    }
    final problem = pinProblem(newPin);
    if (problem != null) throw PinPolicyException(problem);
    if (newPin == currentPin) {
      throw PinPolicyException('Choose a different PIN from the current one.');
    }
    await _storePin(id, newPin);
  }

  Future<void> _storePin(int id, String pin) async {
    final salt = _hasher.newSalt();
    await (_db.update(_db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(
        secretHash: Value(_hasher.hash(pin, salt)),
        secretSalt: Value(salt),
      ),
    );
  }

  /// Deactivating keeps the person's history (sales, notes) and blocks sign-in.
  /// Accounts are never deleted. [actingUserId] cannot deactivate themselves.
  Future<void> setActive(
    int id,
    bool active, {
    required int actingUserId,
  }) async {
    final user = await _require(id);
    if (!active) {
      if (id == actingUserId) {
        throw StaffRuleException('You cannot deactivate your own account.');
      }
      if (user.role == Role.owner &&
          user.active &&
          await _activeOwnerCount() <= 1) {
        throw StaffRuleException(
          'This is the only owner. It cannot be deactivated.',
        );
      }
    }
    await (_db.update(_db.users)..where((u) => u.id.equals(id))).write(
      UsersCompanion(active: Value(active)),
    );
  }

  /// Key for the lockout shared by every discount-approval attempt. User ids
  /// start at 1, so 0 never clashes with a real account.
  static const approverLockKey = 0;

  /// For discounts: whose PIN is this, among active owners and clinicians?
  /// Returns that person, or null if it matches nobody. Wrong guesses share one
  /// lockout, so the approval sheet cannot be used to guess PINs freely.
  Future<User?> verifyApprover(String pin) async {
    final left = lockedSeconds(approverLockKey);
    if (left > 0) throw PinLockedException(left);

    final candidates =
        await (_db.select(_db.users)..where(
              (u) =>
                  u.active.equals(true) &
                  (u.role.equalsValue(Role.owner) |
                      u.role.equalsValue(Role.clinician)),
            ))
            .get();
    for (final u in candidates) {
      if (_hasher.verify(pin, u.secretSalt, u.secretHash)) {
        _failures.remove(approverLockKey);
        return u;
      }
    }
    final n = (_failures[approverLockKey] ?? 0) + 1;
    if (n >= AppConfig.pinMaxAttempts) {
      _failures.remove(approverLockKey);
      _lockedUntil[approverLockKey] = _now().add(AppConfig.pinLockout);
    } else {
      _failures[approverLockKey] = n;
    }
    return null;
  }

  /// Seconds left on a lockout for [userId], or 0.
  int lockedSeconds(int userId) {
    final until = _lockedUntil[userId];
    if (until == null) return 0;
    final left = until.difference(_now()).inSeconds + 1;
    if (left <= 0) {
      _lockedUntil.remove(userId);
      return 0;
    }
    return left;
  }

  /// Returns the user when the PIN is right, null when it is wrong.
  /// Throws [PinLockedException] during a lockout.
  Future<User?> signIn(int userId, String pin) async {
    final left = lockedSeconds(userId);
    if (left > 0) throw PinLockedException(left);

    final user =
        await (_db.select(_db.users)
              ..where((u) => u.id.equals(userId) & u.active.equals(true)))
            .getSingleOrNull();
    if (user == null) return null;

    if (_hasher.verify(pin, user.secretSalt, user.secretHash)) {
      _failures.remove(userId);
      return user;
    }
    final n = (_failures[userId] ?? 0) + 1;
    if (n >= AppConfig.pinMaxAttempts) {
      _failures.remove(userId);
      _lockedUntil[userId] = _now().add(AppConfig.pinLockout);
    } else {
      _failures[userId] = n;
    }
    return null;
  }
}

class PinLockedException implements Exception {
  PinLockedException(this.seconds);
  final int seconds;
  @override
  String toString() =>
      'Too many wrong PINs. Try again in $seconds seconds, or ask the owner to reset it.';
}
