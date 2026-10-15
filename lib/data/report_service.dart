import 'package:drift/drift.dart';

import '../domain/stock_rules.dart';
import 'database.dart';
import 'stock_service.dart';
import 'tables.dart';

/// One medicine's sales in a period.
class TopMedicine {
  const TopMedicine({
    required this.medicine,
    required this.qtyBaseUnits,
    required this.revenueCents,
  });
  final Medicine medicine;
  final int qtyBaseUnits;

  /// Line totals before any whole-sale discount, less what was handed back.
  final int revenueCents;
}

class DayTotal {
  const DayTotal({
    required this.day,
    required this.salesCount,
    required this.totalCents,
  });
  final DateTime day;
  final int salesCount, totalCents;
}

class CashierTotal {
  const CashierTotal({
    required this.name,
    required this.salesCount,
    required this.totalCents,
  });
  final String name;
  final int salesCount, totalCents;
}

/// Money taken in the period, split by how it was paid.
class SalesReport {
  const SalesReport({
    required this.from,
    required this.to,
    required this.salesCount,
    required this.voidedCount,
    required this.grossCents,
    required this.discountCents,
    required this.refundCents,
    required this.cashCents,
    required this.mpesaCents,
    required this.topMedicines,
    required this.days,
    required this.cashiers,
  });

  /// The period is [from] up to but not including [to].
  final DateTime from, to;
  final int salesCount, voidedCount;

  /// Sum of sale subtotals, before discounts.
  final int grossCents;
  final int discountCents;

  /// Refunds paid out in the period (for sales made in it or earlier).
  final int refundCents;

  /// Net of refunds, by how the customer paid or was repaid.
  final int cashCents, mpesaCents;
  final List<TopMedicine> topMedicines;
  final List<DayTotal> days;
  final List<CashierTotal> cashiers;

  /// What the shop kept: sales after discounts, less refunds.
  int get netCents => grossCents - discountCents - refundCents;

  bool get isEmpty => salesCount == 0 && voidedCount == 0 && refundCents == 0;
}

class StockValueLine {
  const StockValueLine(this.stock, this.valueCents);
  final MedicineStock stock;

  /// On-hand quantity at cost; batches with no recorded cost count as zero.
  final int valueCents;
}

class StockReport {
  const StockReport({
    required this.low,
    required this.expiringSoon,
    required this.expired,
    required this.outOfStock,
    required this.valueCents,
    required this.unpricedBatches,
    required this.medicineCount,
  });
  final List<MedicineStock> low, expiringSoon, expired, outOfStock;

  /// All stock on hand at cost.
  final int valueCents;

  /// Batches with stock but no cost, which the value leaves out.
  final int unpricedBatches;
  final int medicineCount;
}

/// Read-only summaries for the owner.
class ReportService {
  ReportService(this._db, this._stock);

  final AppDatabase _db;
  final StockService _stock;

  Future<SalesReport> sales({
    required DateTime from,
    required DateTime to,
  }) async {
    final all =
        await (_db.select(_db.sales)..where(
              (s) =>
                  s.createdAt.isBiggerOrEqualValue(from) &
                  s.createdAt.isSmallerThanValue(to),
            ))
            .get();
    final done = all.where((s) => s.status == SaleStatus.completed).toList();
    final doneIds = done.map((s) => s.id).toList();

    final users = {
      for (final u in await _db.select(_db.users).get()) u.id: u.displayName,
    };

    // Refunds are counted when they are paid out, not when the sale was made.
    final returns =
        await (_db.select(_db.saleReturns)..where(
              (r) =>
                  r.createdAt.isBiggerOrEqualValue(from) &
                  r.createdAt.isSmallerThanValue(to),
            ))
            .get();
    final refund = returns.fold<int>(0, (a, r) => a + r.refundCents);

    final payments = doneIds.isEmpty
        ? <Payment>[]
        : await (_db.select(
            _db.payments,
          )..where((p) => p.saleId.isIn(doneIds))).get();
    int paid(PaymentMethod m) =>
        payments
            .where((p) => p.method == m)
            .fold(0, (a, p) => a + p.amountCents) -
        returns
            .where((r) => r.refundMethod == m)
            .fold(0, (a, r) => a + r.refundCents);

    // Top medicines: items on completed sales, less anything returned.
    final items = doneIds.isEmpty
        ? <SaleItem>[]
        : await (_db.select(
            _db.saleItems,
          )..where((i) => i.saleId.isIn(doneIds))).get();
    final itemReturns = items.isEmpty
        ? <SaleReturn>[]
        : await (_db.select(
            _db.saleReturns,
          )..where((r) => r.saleItemId.isIn(items.map((i) => i.id)))).get();
    final meds = {
      for (final m in await _db.select(_db.medicines).get()) m.id: m,
    };
    final qty = <int, int>{}, rev = <int, int>{};
    for (final i in items) {
      qty[i.medicineId] = (qty[i.medicineId] ?? 0) + i.qtyBaseUnits;
      rev[i.medicineId] = (rev[i.medicineId] ?? 0) + i.lineTotalCents;
    }
    for (final r in itemReturns) {
      final item = items.firstWhere((i) => i.id == r.saleItemId);
      qty[item.medicineId] = qty[item.medicineId]! - r.qtyBaseUnits;
      rev[item.medicineId] = rev[item.medicineId]! - r.refundCents;
    }
    final top = [
      for (final id in qty.keys)
        if (qty[id]! > 0 && meds[id] != null)
          TopMedicine(
            medicine: meds[id]!,
            qtyBaseUnits: qty[id]!,
            revenueCents: rev[id]!,
          ),
    ]..sort((a, b) => b.revenueCents.compareTo(a.revenueCents));

    final byDay = <DateTime, List<Sale>>{};
    for (final s in done) {
      final d = DateTime(s.createdAt.year, s.createdAt.month, s.createdAt.day);
      byDay.putIfAbsent(d, () => []).add(s);
    }
    final byCashier = <int, List<Sale>>{};
    for (final s in done) {
      byCashier.putIfAbsent(s.cashierId, () => []).add(s);
    }
    int sum(List<Sale> l) => l.fold(0, (a, s) => a + s.totalCents);

    return SalesReport(
      from: from,
      to: to,
      salesCount: done.length,
      voidedCount: all.length - done.length,
      grossCents: done.fold(0, (a, s) => a + s.subtotalCents),
      discountCents: done.fold(0, (a, s) => a + s.discountCents),
      refundCents: refund,
      cashCents: paid(PaymentMethod.cash),
      mpesaCents: paid(PaymentMethod.mpesa),
      topMedicines: top,
      days: [
        for (final e
            in byDay.entries.toList()..sort((a, b) => b.key.compareTo(a.key)))
          DayTotal(
            day: e.key,
            salesCount: e.value.length,
            totalCents: sum(e.value),
          ),
      ],
      cashiers: [
        for (final e in byCashier.entries)
          CashierTotal(
            name: users[e.key] ?? 'Unknown',
            salesCount: e.value.length,
            totalCents: sum(e.value),
          ),
      ]..sort((a, b) => b.totalCents.compareTo(a.totalCents)),
    );
  }

  Future<StockReport> stock() async {
    final all = await _stock.listStock();
    var value = 0, unpriced = 0;
    for (final s in all) {
      for (final b in s.batches.where((b) => b.onHand > 0)) {
        final cost = b.batch.costPerUnitCents;
        if (cost == null) {
          unpriced++;
        } else {
          value += cost * b.onHand;
        }
      }
    }
    return StockReport(
      low: [
        for (final s in all)
          if (s.isLow && s.onHand > 0) s,
      ],
      outOfStock: [
        for (final s in all)
          if (s.onHand == 0) s,
      ],
      expiringSoon: [
        for (final s in all)
          if (s.expiresSoon) s,
      ],
      expired: [
        for (final s in all)
          if (s.hasExpired) s,
      ],
      valueCents: value,
      unpricedBatches: unpriced,
      medicineCount: all.length,
    );
  }

  /// The sales summary as CSV, for pasting into a spreadsheet.
  static String salesCsv(SalesReport r) {
    String esc(String s) =>
        s.contains(RegExp(r'[",\n]')) ? '"${s.replaceAll('"', '""')}"' : s;
    String kes(int c) => (c / 100).toStringAsFixed(2);
    String d(DateTime x) =>
        '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final b = StringBuffer()
      ..writeln(
        'Sales report,${d(r.from)} to ${d(r.to.subtract(const Duration(days: 1)))}',
      )
      ..writeln('Sales,${r.salesCount}')
      ..writeln('Cancelled,${r.voidedCount}')
      ..writeln('Before discounts,${kes(r.grossCents)}')
      ..writeln('Discounts,${kes(r.discountCents)}')
      ..writeln('Refunds,${kes(r.refundCents)}')
      ..writeln('Net sales,${kes(r.netCents)}')
      ..writeln('Cash,${kes(r.cashCents)}')
      ..writeln('M-Pesa,${kes(r.mpesaCents)}')
      ..writeln()
      ..writeln('Day,Sales,Total');
    for (final x in r.days) {
      b.writeln('${d(x.day)},${x.salesCount},${kes(x.totalCents)}');
    }
    b
      ..writeln()
      ..writeln('Medicine,Quantity,Unit,Revenue');
    for (final m in r.topMedicines) {
      b.writeln(
        '${esc(m.medicine.name)},${m.qtyBaseUnits},${esc(m.medicine.baseUnitName)},${kes(m.revenueCents)}',
      );
    }
    return b.toString();
  }
}
