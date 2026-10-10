import '../data/database.dart';
import '../data/tables.dart';
import 'stock_rules.dart';

/// What the cashier put in the cart: a medicine, how it is sold, how many.
class CartLine {
  const CartLine({
    required this.medicineId,
    required this.mode,
    required this.count,
  });
  final int medicineId;
  final PriceMode mode;
  final int count;

  CartLine copyWith({PriceMode? mode, int? count}) => CartLine(
    medicineId: medicineId,
    mode: mode ?? this.mode,
    count: count ?? this.count,
  );
}

/// Part of a line taken from one batch.
class Allocation {
  const Allocation({
    required this.batchId,
    required this.batchNumber,
    required this.expiry,
    required this.baseQty,
    required this.totalCents,
    required this.expired,
  });
  final int batchId;
  final String batchNumber;
  final DateTime? expiry;
  final int baseQty;
  final int totalCents;
  final bool expired;
}

/// A cart line priced and matched to batches.
class PricedLine {
  const PricedLine({
    required this.line,
    required this.medicine,
    required this.baseQty,
    required this.totalCents,
    required this.allocations,
    required this.shortBy,
    required this.notSoldThisWay,
  });
  final CartLine line;
  final Medicine medicine;

  /// What leaves stock, in base units.
  final int baseQty;
  final int totalCents;
  final List<Allocation> allocations;

  /// Base units that no batch can supply. 0 when fully covered.
  final int shortBy;

  /// The medicine's prices changed and this way of selling is gone.
  final bool notSoldThisWay;

  bool get hasExpired => allocations.any((a) => a.expired);
  bool get isValid => shortBy == 0 && !notSoldThisWay && line.count > 0;
}

class CartQuote {
  const CartQuote(this.lines);
  final List<PricedLine> lines;

  int get subtotalCents => lines.fold(0, (s, l) => s + l.totalCents);
  bool get hasExpired => lines.any((l) => l.hasExpired);
  bool get isValid => lines.isNotEmpty && lines.every((l) => l.isValid);
}

/// Batches in the order a sale should take from them: earliest expiry first
/// among usable ones, those without an expiry after, and expired stock only as
/// a last resort (the cashier is warned when it is used).
List<BatchStock> saleOrder(MedicineStock s) {
  final withStock = s.batches.where((b) => b.onHand > 0).toList();
  int byExpiry(BatchStock a, BatchStock b) {
    final x = a.batch.expiryDate, y = b.batch.expiryDate;
    if (x == null && y == null) return a.batch.id.compareTo(b.batch.id);
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  }

  bool expired(BatchStock b) =>
      expiryState(b.batch.expiryDate, s.now) == ExpiryState.expired;
  return [
    ...(withStock.where((b) => !expired(b)).toList()..sort(byExpiry)),
    ...(withStock.where(expired).toList()..sort(byExpiry)),
  ];
}

/// Prices every line and takes stock from batches in [saleOrder]. Lines for
/// the same medicine share the same batches, in cart order.
CartQuote quoteCart(List<CartLine> lines, Map<int, MedicineStock> stock) {
  final remaining = <int, int>{}; // batchId -> units still free
  final priced = <PricedLine>[];

  for (final line in lines) {
    final ms = stock[line.medicineId];
    if (ms == null) continue; // medicine removed or deactivated
    final m = ms.medicine;
    final price = offeredModes(m).contains(line.mode)
        ? priceCents(m, line.mode)
        : null;
    if (price == null) {
      priced.add(
        PricedLine(
          line: line,
          medicine: m,
          baseQty: 0,
          totalCents: 0,
          allocations: const [],
          shortBy: 0,
          notSoldThisWay: true,
        ),
      );
      continue;
    }

    final need = line.count * unitsIn(m, line.mode);
    final total = line.count * price;
    final taken = <(BatchStock, int)>[];
    var left = need;
    for (final b in saleOrder(ms)) {
      if (left == 0) break;
      final free = remaining.putIfAbsent(b.batch.id, () => b.onHand);
      if (free <= 0) continue;
      final take = free < left ? free : left;
      remaining[b.batch.id] = free - take;
      taken.add((b, take));
      left -= take;
    }

    // Split the line total across batches in proportion; the last part takes
    // the rounding remainder so the parts always add up exactly.
    final allocs = <Allocation>[];
    var assigned = 0;
    for (var i = 0; i < taken.length; i++) {
      final (b, qty) = taken[i];
      final isLast = i == taken.length - 1 && left == 0;
      final part = isLast ? total - assigned : (total * qty / need).round();
      assigned += part;
      allocs.add(
        Allocation(
          batchId: b.batch.id,
          batchNumber: b.batch.batchNumber,
          expiry: b.batch.expiryDate,
          baseQty: qty,
          totalCents: part,
          expired:
              expiryState(b.batch.expiryDate, ms.now) == ExpiryState.expired,
        ),
      );
    }

    priced.add(
      PricedLine(
        line: line,
        medicine: m,
        baseQty: need,
        totalCents: total,
        allocations: allocs,
        shortBy: left,
        notSoldThisWay: false,
      ),
    );
  }
  return CartQuote(priced);
}
