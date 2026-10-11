import 'dart:convert';

import 'package:drift/drift.dart';

import '../domain/cart.dart';
import 'database.dart';
import 'tables.dart';

/// A parked-sale rule was broken. The message is shown as written.
class HeldSaleException implements Exception {
  HeldSaleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A sale set aside before payment, ready to be picked up again.
class HeldSale {
  const HeldSale({
    required this.id,
    required this.label,
    required this.lines,
    required this.discountCents,
    required this.approverId,
    required this.approverName,
    required this.parkedByName,
    required this.createdAt,
  });
  final int id;
  final String? label;
  final List<CartLine> lines;
  final int discountCents;
  final int? approverId;
  final String? approverName;
  final String parkedByName;
  final DateTime createdAt;
}

/// Parking sales so a customer can come back to them. Parking holds no stock:
/// quantities and prices are checked again when the sale is resumed and paid.
class HeldSalesService {
  HeldSalesService(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  /// Enough for a busy counter; more means sales are being forgotten.
  static const maxParked = 20;
  static const maxLabelLength = 40;

  static String _encode(List<CartLine> lines) => jsonEncode([
    for (final l in lines)
      {'m': l.medicineId, 'mode': l.mode.name, 'n': l.count},
  ]);

  /// Tolerant on purpose: one damaged entry must not lose the whole sale.
  static List<CartLine> _decode(String json) {
    final out = <CartLine>[];
    try {
      for (final e in jsonDecode(json) as List) {
        final m = e as Map;
        final mode = PriceMode.values.where((p) => p.name == m['mode']);
        final id = m['m'], n = m['n'];
        if (mode.isEmpty || id is! int || n is! int || n < 1) continue;
        out.add(CartLine(medicineId: id, mode: mode.first, count: n));
      }
    } catch (_) {
      return const [];
    }
    return out;
  }

  Future<int> park({
    required List<CartLine> lines,
    required int userId,
    String? label,
    int discountCents = 0,
    int? discountApprovedBy,
  }) async {
    if (lines.isEmpty) throw HeldSaleException('There is nothing to park.');
    if (discountCents > 0 && discountApprovedBy == null) {
      throw HeldSaleException('A discount needs an approver to be parked.');
    }
    final name = label?.trim();
    if (name != null && name.length > maxLabelLength) {
      throw HeldSaleException(
        'Keep the name to $maxLabelLength characters or fewer.',
      );
    }
    if (await count() >= maxParked) {
      throw HeldSaleException(
        'There are already $maxParked parked sales. Finish or discard some first.',
      );
    }
    return _db
        .into(_db.heldSales)
        .insert(
          HeldSalesCompanion.insert(
            label: Value((name == null || name.isEmpty) ? null : name),
            linesJson: _encode(lines),
            discountCents: Value(discountCents),
            discountApprovedBy: Value(discountApprovedBy),
            parkedBy: userId,
            createdAt: Value(_now()),
          ),
        );
  }

  Future<int> count() async {
    final r = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM held_sales',
          readsFrom: {_db.heldSales},
        )
        .getSingle();
    return r.read<int>('n');
  }

  /// Oldest first, so the customer who has waited longest is at the top.
  Future<List<HeldSale>> list() async {
    final rows = await (_db.select(
      _db.heldSales,
    )..orderBy([(h) => OrderingTerm.asc(h.id)])).get();
    if (rows.isEmpty) return const [];
    final users = {
      for (final u in await _db.select(_db.users).get()) u.id: u.displayName,
    };
    return [for (final h in rows) _toHeld(h, users)];
  }

  HeldSale _toHeld(HeldSaleRow h, Map<int, String> users) => HeldSale(
    id: h.id,
    label: h.label,
    lines: _decode(h.linesJson),
    discountCents: h.discountCents,
    approverId: h.discountApprovedBy,
    approverName: users[h.discountApprovedBy],
    parkedByName: users[h.parkedBy] ?? 'Unknown',
    createdAt: h.createdAt,
  );

  /// Takes a parked sale out of the list and returns it. It is removed in the
  /// same step, so two people cannot both pick it up.
  Future<HeldSale> take(int id) {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.heldSales,
      )..where((h) => h.id.equals(id))).getSingleOrNull();
      if (row == null) {
        throw HeldSaleException(
          'That parked sale is gone. Someone else may have picked it up.',
        );
      }
      final users = {
        for (final u in await _db.select(_db.users).get()) u.id: u.displayName,
      };
      await (_db.delete(_db.heldSales)..where((h) => h.id.equals(id))).go();
      return _toHeld(row, users);
    });
  }

  Future<void> discard(int id) =>
      (_db.delete(_db.heldSales)..where((h) => h.id.equals(id))).go();
}
