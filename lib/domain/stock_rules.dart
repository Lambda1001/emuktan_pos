import '../config/app_config.dart';
import '../data/database.dart';
import '../data/tables.dart';

/// Pure stock rules. No database, no widgets, so they are easy to test.

enum ExpiryState { none, ok, soon, expired }

/// A batch is usable until the END of its expiry day (expiry is stored as the
/// last day of the printed month), and expired from the day after.
ExpiryState expiryState(DateTime? expiry, DateTime now) {
  if (expiry == null) return ExpiryState.none;
  final today = DateTime(now.year, now.month, now.day);
  if (today.isAfter(expiry)) return ExpiryState.expired;
  if (expiry.difference(today).inDays <= StockConfig.expiringSoonDays) {
    return ExpiryState.soon;
  }
  return ExpiryState.ok;
}

/// 0 means the owner has not set a reorder level, so never flagged.
bool isLowStock({required int sellable, required int threshold}) =>
    threshold > 0 && sellable <= threshold;

/// The ways this medicine is actually sold, cheapest unit last.
List<PriceMode> offeredModes(Medicine m) => [
  if (m.pricePerPackCents != null && m.unitsPerPack != null) PriceMode.pack,
  if (m.pricePerStripCents != null && m.unitsPerStrip != null) PriceMode.strip,
  if (m.pricePerUnitCents != null) PriceMode.unit,
];

/// How many base units one of [mode] contains.
int unitsIn(Medicine m, PriceMode mode) => switch (mode) {
  PriceMode.pack => m.unitsPerPack!,
  PriceMode.strip => m.unitsPerStrip!,
  PriceMode.unit => 1,
};

int? priceCents(Medicine m, PriceMode mode) => switch (mode) {
  PriceMode.pack => m.pricePerPackCents,
  PriceMode.strip => m.pricePerStripCents,
  PriceMode.unit => m.pricePerUnitCents,
};

String modeLabel(PriceMode mode) => switch (mode) {
  PriceMode.pack => 'Pack',
  PriceMode.strip => 'Strip',
  PriceMode.unit => 'Single',
};

/// One batch with how much of it is left.
class BatchStock {
  const BatchStock(this.batch, this.onHand);
  final Batch batch;
  final int onHand;
}

/// A medicine with its batches, as the Stock screen needs it.
class MedicineStock {
  MedicineStock(this.medicine, this.batches, this.now);
  final Medicine medicine;
  final List<BatchStock> batches;
  final DateTime now;

  Iterable<BatchStock> get _withStock => batches.where((b) => b.onHand > 0);

  int get onHand => batches.fold(0, (s, b) => s + b.onHand);

  int get expiredQty => _withStock
      .where((b) => expiryState(b.batch.expiryDate, now) == ExpiryState.expired)
      .fold(0, (s, b) => s + b.onHand);

  /// Stock that could be sold today (not expired).
  int get sellable => onHand - expiredQty;

  bool get hasExpired => expiredQty > 0;

  bool get isLow =>
      isLowStock(sellable: sellable, threshold: medicine.lowStockThreshold);

  /// Earliest expiry among sellable batches, or null.
  DateTime? get nextExpiry {
    final dates =
        _withStock
            .where(
              (b) =>
                  expiryState(b.batch.expiryDate, now) != ExpiryState.expired,
            )
            .map((b) => b.batch.expiryDate)
            .whereType<DateTime>()
            .toList()
          ..sort();
    return dates.isEmpty ? null : dates.first;
  }

  bool get expiresSoon => _withStock.any(
    (b) => expiryState(b.batch.expiryDate, now) == ExpiryState.soon,
  );

  /// The batch a sale takes from first: earliest expiry that is not expired,
  /// batches without an expiry last (DESIGN.md section 8, rule 3).
  BatchStock? get nextBatchToSell {
    final usable =
        _withStock
            .where(
              (b) =>
                  expiryState(b.batch.expiryDate, now) != ExpiryState.expired,
            )
            .toList()
          ..sort((a, b) {
            final x = a.batch.expiryDate, y = b.batch.expiryDate;
            if (x == null && y == null) return a.batch.id.compareTo(b.batch.id);
            if (x == null) return 1;
            if (y == null) return -1;
            return x.compareTo(y);
          });
    return usable.isEmpty ? null : usable.first;
  }
}
