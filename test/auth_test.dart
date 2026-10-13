import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:emuktan_pos/config/app_config.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/features/shell/destinations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fast = PinHasher(iterations: 10);

  group('PinHasher', () {
    test('same PIN and salt give the same hash; different salt does not', () {
      final salt = fast.newSalt();
      expect(fast.hash('1234', salt), fast.hash('1234', salt));
      expect(fast.hash('1234', salt), isNot(fast.hash('1234', fast.newSalt())));
    });

    test('verify accepts the right PIN and rejects a wrong one', () {
      final salt = fast.newSalt();
      final h = fast.hash('2580', salt);
      expect(fast.verify('2580', salt, h), isTrue);
      expect(fast.verify('2581', salt, h), isFalse);
    });

    test(
      'matches .NET PBKDF2-HMAC-SHA256 (password "passwd", salt "saltsalt")',
      () {
        // Reference values from System.Security.Cryptography.Rfc2898DeriveBytes.
        const salt = 'c2FsdHNhbHQ='; // base64("saltsalt")
        expect(
          const PinHasher(iterations: 1).hash('passwd', salt),
          'lDmP6RuFMH8YWoefiEoq4eTqKXQV5Oep0voixqMnpBw=',
        );
        expect(
          const PinHasher(iterations: 2).hash('passwd', salt),
          'nePjM75NrquRh/vGhA50Kx0pXhgDZNUqXNbQsWopqzY=',
        );
      },
    );
  });

  group('AuthService', () {
    late AppDatabase db;
    late DateTime now;
    late AuthService auth;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      now = DateTime(2026, 10, 10, 9);
      auth = AuthService(db, hasher: fast, clock: () => now);
    });
    tearDown(() => db.close());

    test('no users until the owner is created', () async {
      expect(await auth.hasAnyUser(), isFalse);
      await auth.createUser(
        displayName: 'Wanjiru Kamau',
        role: Role.owner,
        pin: '4821',
      );
      expect(await auth.hasAnyUser(), isTrue);
    });

    test('PIN is stored hashed, never in plain text', () async {
      final u = await auth.createUser(
        displayName: 'Wanjiru Kamau',
        role: Role.owner,
        pin: '4821',
      );
      expect(u.secretHash, isNot(contains('4821')));
      expect(u.secretHash, isNotEmpty);
    });

    test('usernames stay unique for people with the same name', () async {
      final a = await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '1357',
      );
      final b = await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '2468',
      );
      expect(a.username, isNot(b.username));
    });

    test('weak or malformed PINs are refused with a plain message', () async {
      for (final bad in ['12', '1234567', 'abcd', '1111']) {
        expect(AuthService.pinProblem(bad), isNotNull, reason: bad);
        expect(
          () => auth.createUser(
            displayName: 'Jane Doe',
            role: Role.cashier,
            pin: bad,
          ),
          throwsA(isA<PinPolicyException>()),
        );
      }
      expect(AuthService.pinProblem('4821'), isNull);
    });

    test('right PIN signs in, wrong PIN does not', () async {
      final u = await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '1357',
      );
      expect((await auth.signIn(u.id, '1357'))?.id, u.id);
      expect(await auth.signIn(u.id, '9999'), isNull);
    });

    test('inactive users cannot sign in', () async {
      final u = await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '1357',
      );
      await (db.update(db.users)..where((x) => x.id.equals(u.id))).write(
        const UsersCompanion(active: Value(false)),
      );
      expect(await auth.signIn(u.id, '1357'), isNull);
      expect(await auth.activeUsers(), isEmpty);
    });

    test('repeated wrong PINs lock sign-in, then it unlocks', () async {
      final u = await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '1357',
      );
      for (var i = 0; i < AppConfig.pinMaxAttempts; i++) {
        expect(await auth.signIn(u.id, '0000'), isNull);
      }
      expect(auth.lockedSeconds(u.id), greaterThan(0));
      // Even the right PIN is refused during the lockout.
      await expectLater(
        auth.signIn(u.id, '1357'),
        throwsA(isA<PinLockedException>()),
      );

      now = now.add(AppConfig.pinLockout + const Duration(seconds: 1));
      expect(auth.lockedSeconds(u.id), 0);
      expect((await auth.signIn(u.id, '1357'))?.id, u.id);
    });
  });

  group('navigation by role', () {
    test('cashier and clinician do not see Reports or Staff and settings', () {
      for (final r in [Role.cashier, Role.clinician]) {
        final d = destinationsFor(r);
        expect(
          d,
          containsAll([
            Destination.sell,
            Destination.patients,
            Destination.stock,
          ]),
        );
        expect(d, isNot(contains(Destination.reports)));
        expect(d, isNot(contains(Destination.settings)));
      }
    });

    test('owner sees everything', () {
      expect(destinationsFor(Role.owner), Destination.values);
    });
  });
}
