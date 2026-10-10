import 'package:drift/drift.dart';

import '../domain/stock_rules.dart';
import 'database.dart';
import 'tables.dart';

/// A stock rule was broken. The message is shown to the user as written.
class StockRuleException implements Exception {
  StockRuleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What the owner enters for a medicine. Prices are cents.
class MedicineInput {
  const MedicineInput({
    required this.name,
    this.genericName,
    this.barcode,
    this.baseUnitName = 'tablet',
    this.unitsPerStrip,
    this.unitsPerPack,
    this.pricePerPackCents,
    this.pricePerStripCents,
    this.pricePerUnitCents,
    this.lowStockThreshold = 0,
  });

  final String name;
  final String? genericName, barcode;
  final String baseUnitName;
  final int? unitsPerStrip, unitsPerPack;
  final int? pricePerPackCents, pricePerStripCents, pricePerUnitCents;
  final int lowStockThreshold;
}

class StockService {
  StockService(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  // ---- Reading ----------------------------------------------------------

  /// Every medicine with its batches and what is left in each.
  Future<List<MedicineStock>> listStock({bool includeInactive = false}) async {
    final meds =
        await (_db.select(_db.medicines)
              ..where(
                (m) => includeInactive
                    ? const Constant(true)
                    : m.active.equals(true),
              )
              ..orderBy([(m) => OrderingTerm.asc(m.name)]))
            .get();
    final batches = await _db.select(_db.batches).get();
    final sums = await _db
        .customSelect(
          'SELECT batch_id, SUM(qty_delta) AS q FROM stock_movements GROUP BY batch_id',
          readsFrom: {_db.stockMovements},
        )
        .get();
    final onHand = {
      for (final r in sums) r.read<int>('batch_id'): r.read<int>('q'),
    };

    final byMed = <int, List<BatchStock>>{};
    for (final b in batches) {
      byMed
          .putIfAbsent(b.medicineId, () => [])
          .add(BatchStock(b, onHand[b.id] ?? 0));
    }
    final now = _now();
    return [
      for (final m in meds)
        MedicineStock(m, (byMed[m.id] ?? [])..sort(_byExpiry), now),
    ];
  }

  static int _byExpiry(BatchStock a, BatchStock b) {
    final x = a.batch.expiryDate, y = b.batch.expiryDate;
    if (x == null && y == null) return a.batch.id.compareTo(b.batch.id);
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }

  // ---- Medicines --------------------------------------------------------

  Future<void> _validate(MedicineInput i, {int? existingId}) async {
    if (i.name.trim().length < 2) {
      throw StockRuleException('Enter the medicine name.');
    }
    if (i.baseUnitName.trim().isEmpty) {
      throw StockRuleException(
        'Enter the smallest unit it is counted in, for example tablet or ml.',
      );
    }
    final strip = i.unitsPerStrip, pack = i.unitsPerPack;
    if (strip != null && strip < 2) {
      throw StockRuleException(
        'A strip must hold at least 2 ${i.baseUnitName.trim()}s.',
      );
    }
    if (pack != null && pack < 2) {
      throw StockRuleException(
        'A pack must hold at least 2 ${i.baseUnitName.trim()}s.',
      );
    }
    if (strip != null && pack != null) {
      if (pack <= strip || pack % strip != 0) {
        throw StockRuleException(
          'A pack must be a whole number of strips. '
          'Check the numbers: $pack per pack, $strip per strip.',
        );
      }
    }
    if (i.pricePerPackCents != null && pack == null) {
      throw StockRuleException(
        'Enter how many are in a pack, or remove the pack price.',
      );
    }
    if (i.pricePerStripCents != null && strip == null) {
      throw StockRuleException(
        'Enter how many are in a strip, or remove the strip price.',
      );
    }
    final prices = [
      i.pricePerPackCents,
      i.pricePerStripCents,
      i.pricePerUnitCents,
    ];
    if (prices.every((p) => p == null)) {
      throw StockRuleException('Enter at least one selling price.');
    }
    if (prices.any((p) => p != null && p <= 0)) {
      throw StockRuleException('Prices must be more than zero.');
    }
    if (i.lowStockThreshold < 0) {
      throw StockRuleException('The low-stock level cannot be negative.');
    }

    final dupName = await (_db.select(
      _db.medicines,
    )..where((m) => m.name.lower().equals(i.name.trim().toLowerCase()))).get();
    if (dupName.any((m) => m.id != existingId)) {
      throw StockRuleException('A medicine with this name already exists.');
    }
    final code = _clean(i.barcode);
    if (code != null) {
      final dupCode = await (_db.select(
        _db.medicines,
      )..where((m) => m.barcode.equals(code))).get();
      if (dupCode.any((m) => m.id != existingId)) {
        throw StockRuleException('Another medicine already uses this barcode.');
      }
    }
  }

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  Future<int> createMedicine(MedicineInput i, {required int userId}) async {
    await _validate(i);
    return _db
        .into(_db.medicines)
        .insert(
          MedicinesCompanion.insert(
            name: i.name.trim(),
            genericName: Value(_clean(i.genericName)),
            barcode: Value(_clean(i.barcode)),
            baseUnitName: Value(i.baseUnitName.trim()),
            unitsPerStrip: Value(i.unitsPerStrip),
            unitsPerPack: Value(i.unitsPerPack),
            pricePerPackCents: Value(i.pricePerPackCents),
            pricePerStripCents: Value(i.pricePerStripCents),
            pricePerUnitCents: Value(i.pricePerUnitCents),
            lowStockThreshold: Value(i.lowStockThreshold),
            createdBy: userId,
          ),
        );
  }

  Future<void> updateMedicine(int id, MedicineInput i) async {
    await _validate(i, existingId: id);
    final updated =
        await (_db.update(_db.medicines)..where((m) => m.id.equals(id))).write(
          MedicinesCompanion(
            name: Value(i.name.trim()),
            genericName: Value(_clean(i.genericName)),
            barcode: Value(_clean(i.barcode)),
            baseUnitName: Value(i.baseUnitName.trim()),
            unitsPerStrip: Value(i.unitsPerStrip),
            unitsPerPack: Value(i.unitsPerPack),
            pricePerPackCents: Value(i.pricePerPackCents),
            pricePerStripCents: Value(i.pricePerStripCents),
            pricePerUnitCents: Value(i.pricePerUnitCents),
            lowStockThreshold: Value(i.lowStockThreshold),
            updatedAt: Value(_now()),
          ),
        );
    if (updated == 0) {
      throw StockRuleException('That medicine no longer exists.');
    }
  }

  /// Medicines are never deleted: sales history points at them.
  Future<void> setMedicineActive(int id, bool active) =>
      (_db.update(_db.medicines)..where((m) => m.id.equals(id))).write(
        MedicinesCompanion(active: Value(active), updatedAt: Value(_now())),
      );

  // ---- Receiving --------------------------------------------------------

  /// Adds stock. Creates the batch, or tops up an existing one with the same
  /// number (which must have the same expiry and cost). Quantity is in base
  /// units; cost is cents per base unit.
  Future<int> receiveStock({
    required int medicineId,
    required String batchNumber,
    required DateTime? expiry,
    required int qtyBaseUnits,
    required int costPerUnitCents,
    String? supplierNote,
    required int userId,
  }) async {
    final number = batchNumber.trim();
    if (number.isEmpty) {
      throw StockRuleException('Enter the batch number from the pack.');
    }
    if (qtyBaseUnits <= 0) {
      throw StockRuleException('Enter a quantity more than zero.');
    }
    if (costPerUnitCents < 0) {
      throw StockRuleException('The cost cannot be negative.');
    }
    if (expiry != null && expiryState(expiry, _now()) == ExpiryState.expired) {
      throw StockRuleException(
        'That expiry date has already passed. Do not receive expired stock.',
      );
    }

    return _db.transaction(() async {
      final med = await (_db.select(
        _db.medicines,
      )..where((m) => m.id.equals(medicineId))).getSingleOrNull();
      if (med == null || !med.active) {
        throw StockRuleException(
          'That medicine is not available. Pick another.',
        );
      }
      final existing =
          await (_db.select(_db.batches)..where(
                (b) =>
                    b.medicineId.equals(medicineId) &
                    b.batchNumber.equals(number),
              ))
              .getSingleOrNull();

      int batchId;
      if (existing == null) {
        batchId = await _db
            .into(_db.batches)
            .insert(
              BatchesCompanion.insert(
                medicineId: medicineId,
                batchNumber: number,
                expiryDate: Value(expiry),
                costPerUnitCents: Value(costPerUnitCents),
                supplierNote: Value(_clean(supplierNote)),
                createdBy: userId,
              ),
            );
      } else {
        final sameExpiry = existing.expiryDate == expiry;
        if (!sameExpiry || existing.costPerUnitCents != costPerUnitCents) {
          throw StockRuleException(
            'Batch $number already exists with a different '
            '${sameExpiry ? 'cost' : 'expiry date'}. Check the pack, or add a '
            'letter to the batch number to keep them separate.',
          );
        }
        batchId = existing.id;
      }
      await _db
          .into(_db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              batchId: batchId,
              qtyDelta: qtyBaseUnits,
              reason: MovementReason.receipt,
              createdBy: userId,
            ),
          );
      return batchId;
    });
  }

  // ---- Adjusting --------------------------------------------------------

  /// Corrections and write-offs. A reason in words is required so the history
  /// explains itself. Stock can never go below zero.
  Future<void> adjustStock({
    required int batchId,
    required int qtyDelta,
    required MovementReason reason,
    required String note,
    required int userId,
  }) async {
    const allowed = {
      MovementReason.adjustment,
      MovementReason.writeOffExpired,
      MovementReason.writeOffDamaged,
    };
    if (!allowed.contains(reason)) {
      throw StockRuleException('That kind of change is not allowed here.');
    }
    if (qtyDelta == 0) throw StockRuleException('Enter how many to change by.');
    if (reason != MovementReason.adjustment && qtyDelta > 0) {
      throw StockRuleException(
        'A write-off removes stock. Enter a quantity to remove.',
      );
    }
    if (note.trim().length < 3) {
      throw StockRuleException('Say why, in a few words.');
    }

    await _db.transaction(() async {
      final left = await _db.stockOnHand(batchId);
      if (left + qtyDelta < 0) {
        throw StockRuleException(
          'Only $left left in this batch. You cannot remove more than that.',
        );
      }
      await _db
          .into(_db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              batchId: batchId,
              qtyDelta: qtyDelta,
              reason: reason,
              note: Value(note.trim()),
              createdBy: userId,
            ),
          );
    });
  }
}
