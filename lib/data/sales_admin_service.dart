import 'package:drift/drift.dart';

import '../domain/returns.dart';
import 'database.dart';
import 'sales_service.dart' show SaleRuleException;
import 'tables.dart';

/// One row in the sales list.
class SaleSummary {
  const SaleSummary({
    required this.sale,
    required this.cashierName,
    required this.method,
    required this.refundedCents,
  });
  final Sale sale;
  final String cashierName;
  final PaymentMethod? method;
  final int refundedCents;
}

/// One thing sold, with what has come back.
class SaleLine {
  const SaleLine({
    required this.item,
    required this.medicine,
    required this.batchNumber,
    required this.returnedQty,
    required this.refundedCents,
    required this.netCents,
  });
  final SaleItem item;
  final Medicine medicine;
  final String batchNumber;
  final int returnedQty;
  final int refundedCents;

  /// What the customer paid for this line after the discount share.
  final int netCents;

  int get remainingQty => item.qtyBaseUnits - returnedQty;
}

class SaleDetail {
  const SaleDetail({
    required this.sale,
    required this.cashierName,
    required this.lines,
    required this.payments,
    required this.returns,
    required this.discountApproverName,
    required this.voidedByName,
  });
  final Sale sale;
  final String cashierName;
  final List<SaleLine> lines;
  final List<Payment> payments;
  final List<SaleReturn> returns;
  final String? discountApproverName, voidedByName;

  bool get isVoided => sale.status == SaleStatus.voided;
  int get refundedCents => returns.fold(0, (s, r) => s + r.refundCents);

  /// A sale can be cancelled whole only before anything has been returned.
  bool get canVoid => !isVoided && returns.isEmpty;
  bool get canReturn => !isVoided && lines.any((l) => l.remainingQty > 0);
}

/// Looking up past sales, cancelling them, and taking items back.
class SalesAdminService {
  SalesAdminService(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  // ---- Reading ----------------------------------------------------------

  /// Sales since [since], newest first. [receiptQuery] matches part of the
  /// receipt number and ignores [since].
  Future<List<SaleSummary>> recentSales({
    required DateTime since,
    String? receiptQuery,
  }) async {
    final q = receiptQuery?.trim().toUpperCase() ?? '';
    final sales =
        await (_db.select(_db.sales)
              ..where(
                (s) => q.isEmpty
                    ? s.createdAt.isBiggerOrEqualValue(since)
                    : s.receiptNo.like('%$q%'),
              )
              ..orderBy([(s) => OrderingTerm.desc(s.id)])
              ..limit(500))
            .get();
    if (sales.isEmpty) return const [];

    final ids = sales.map((s) => s.id).toList();
    final users = {
      for (final u in await _db.select(_db.users).get()) u.id: u.displayName,
    };
    final pays = await (_db.select(
      _db.payments,
    )..where((p) => p.saleId.isIn(ids))).get();
    final rets = await (_db.select(
      _db.saleReturns,
    )..where((r) => r.saleId.isIn(ids))).get();
    return [
      for (final s in sales)
        SaleSummary(
          sale: s,
          cashierName: users[s.cashierId] ?? 'Unknown',
          method: pays.where((p) => p.saleId == s.id).firstOrNull?.method,
          refundedCents: rets
              .where((r) => r.saleId == s.id)
              .fold(0, (a, r) => a + r.refundCents),
        ),
    ];
  }

  Future<SaleDetail?> detail(int saleId) async {
    final sale = await (_db.select(
      _db.sales,
    )..where((s) => s.id.equals(saleId))).getSingleOrNull();
    if (sale == null) return null;

    final items =
        await (_db.select(_db.saleItems)
              ..where((i) => i.saleId.equals(saleId))
              ..orderBy([(i) => OrderingTerm.asc(i.id)]))
            .get();
    final rets = await (_db.select(
      _db.saleReturns,
    )..where((r) => r.saleId.equals(saleId))).get();
    final meds = {
      for (final m in await _db.select(_db.medicines).get()) m.id: m,
    };
    final batches = {
      for (final b in await _db.select(_db.batches).get()) b.id: b,
    };
    final users = {
      for (final u in await _db.select(_db.users).get()) u.id: u.displayName,
    };
    final net = netLineTotals(
      lineTotals: [for (final i in items) i.lineTotalCents],
      discountCents: sale.discountCents,
    );

    return SaleDetail(
      sale: sale,
      cashierName: users[sale.cashierId] ?? 'Unknown',
      lines: [
        for (var i = 0; i < items.length; i++)
          SaleLine(
            item: items[i],
            medicine: meds[items[i].medicineId]!,
            batchNumber: batches[items[i].batchId]?.batchNumber ?? '?',
            returnedQty: rets
                .where((r) => r.saleItemId == items[i].id)
                .fold(0, (a, r) => a + r.qtyBaseUnits),
            refundedCents: rets
                .where((r) => r.saleItemId == items[i].id)
                .fold(0, (a, r) => a + r.refundCents),
            netCents: net[i],
          ),
      ],
      payments: await (_db.select(
        _db.payments,
      )..where((p) => p.saleId.equals(saleId))).get(),
      returns: rets,
      discountApproverName: users[sale.discountAuthorisedBy],
      voidedByName: users[sale.voidedBy],
    );
  }

  // ---- Changing ---------------------------------------------------------

  Future<void> _requireApprover(int approverId) async {
    final u =
        await (_db.select(_db.users)..where(
              (u) =>
                  u.id.equals(approverId) &
                  u.active.equals(true) &
                  (u.role.equalsValue(Role.owner) |
                      u.role.equalsValue(Role.clinician)),
            ))
            .getSingleOrNull();
    if (u == null) {
      throw SaleRuleException(
        'This needs approval from the owner or a clinician.',
      );
    }
  }

  static String _reason(String reason) {
    final r = reason.trim();
    if (r.length < 3) throw SaleRuleException('Say why, in a few words.');
    return r;
  }

  /// Cancels a whole sale and puts every item back in the batch it came from.
  /// [approverId] is the owner or clinician who approved; [actingUserId] is
  /// the person at the screen. The sale and its payment stay on record.
  Future<void> voidSale({
    required int saleId,
    required String reason,
    required int approverId,
    required int actingUserId,
  }) async {
    final why = _reason(reason);
    await _requireApprover(approverId);
    await _db.transaction(() async {
      final d = await detail(saleId);
      if (d == null) throw SaleRuleException('That sale no longer exists.');
      if (d.isVoided) throw SaleRuleException('This sale is already voided.');
      if (d.returns.isNotEmpty) {
        throw SaleRuleException(
          'Part of this sale has already been returned, so it cannot be voided. '
          'Return the remaining items instead.',
        );
      }
      final now = _now();
      await (_db.update(_db.sales)..where((s) => s.id.equals(saleId))).write(
        SalesCompanion(
          status: const Value(SaleStatus.voided),
          voidedAt: Value(now),
          voidedBy: Value(approverId),
          voidReason: Value(why),
        ),
      );
      for (final l in d.lines) {
        await _db
            .into(_db.stockMovements)
            .insert(
              StockMovementsCompanion.insert(
                batchId: l.item.batchId,
                qtyDelta: l.item.qtyBaseUnits,
                reason: MovementReason.saleVoid,
                saleId: Value(saleId),
                note: Value('Void ${d.sale.receiptNo}: $why'),
                createdBy: actingUserId,
                createdAt: Value(now),
              ),
            );
      }
    });
  }

  /// Takes items back. [qtyByItemId] maps a sale item to base units returned.
  /// Refunds what was actually paid for those units (after the discount
  /// share). With [restock] the units go back into their batch; without it
  /// (damaged, opened) stock is left as it is. Returns the refund in cents.
  Future<int> returnItems({
    required int saleId,
    required Map<int, int> qtyByItemId,
    required String reason,
    required int approverId,
    required int actingUserId,
    required PaymentMethod refundMethod,
    bool restock = true,
  }) async {
    final why = _reason(reason);
    final wanted = {
      for (final e in qtyByItemId.entries)
        if (e.value > 0) e.key: e.value,
    };
    if (wanted.isEmpty) {
      throw SaleRuleException('Choose at least one item to return.');
    }
    await _requireApprover(approverId);

    return _db.transaction(() async {
      final d = await detail(saleId);
      if (d == null) throw SaleRuleException('That sale no longer exists.');
      if (d.isVoided) {
        throw SaleRuleException(
          'This sale was voided, so nothing can be returned.',
        );
      }
      final now = _now();
      var total = 0;
      for (final entry in wanted.entries) {
        final line = d.lines.where((l) => l.item.id == entry.key).firstOrNull;
        if (line == null) {
          throw SaleRuleException('That item is not part of this sale.');
        }
        if (entry.value > line.remainingQty) {
          throw SaleRuleException(
            'Only ${line.remainingQty} of ${line.medicine.name} can still be returned.',
          );
        }
        final refund = refundFor(
          netCents: line.netCents,
          soldQty: line.item.qtyBaseUnits,
          qty: entry.value,
          alreadyReturned: line.returnedQty,
          alreadyRefunded: line.refundedCents,
        );
        total += refund;
        await _db
            .into(_db.saleReturns)
            .insert(
              SaleReturnsCompanion.insert(
                saleId: saleId,
                saleItemId: line.item.id,
                qtyBaseUnits: entry.value,
                refundCents: refund,
                refundMethod: refundMethod,
                restocked: Value(restock),
                reason: why,
                approvedBy: approverId,
                createdBy: actingUserId,
                createdAt: Value(now),
              ),
            );
        if (restock) {
          await _db
              .into(_db.stockMovements)
              .insert(
                StockMovementsCompanion.insert(
                  batchId: line.item.batchId,
                  qtyDelta: entry.value,
                  reason: MovementReason.saleReturn,
                  saleId: Value(saleId),
                  note: Value('Return ${d.sale.receiptNo}: $why'),
                  createdBy: actingUserId,
                  createdAt: Value(now),
                ),
              );
        }
      }
      return total;
    });
  }
}
