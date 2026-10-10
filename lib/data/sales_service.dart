import 'package:drift/drift.dart';

import '../domain/cart.dart';
import '../domain/stock_rules.dart';
import 'database.dart';
import 'stock_service.dart';
import 'tables.dart';

/// A sale rule was broken. The message is shown to the user as written.
class SaleRuleException implements Exception {
  SaleRuleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One line as it appears on the receipt.
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.count,
    required this.mode,
    required this.baseQty,
    required this.baseUnit,
    required this.unitPriceCents,
    required this.totalCents,
  });
  final String name, baseUnit;
  final int count, baseQty, unitPriceCents, totalCents;
  final PriceMode mode;
}

/// Everything needed to show or print a finished sale.
class SaleReceipt {
  const SaleReceipt({
    required this.receiptNo,
    required this.createdAt,
    required this.cashierName,
    required this.lines,
    required this.subtotalCents,
    required this.discountCents,
    required this.approverName,
    required this.totalCents,
    required this.method,
    required this.mpesaCode,
    required this.tenderedCents,
    required this.changeCents,
  });
  final String receiptNo, cashierName;
  final DateTime createdAt;
  final List<ReceiptLine> lines;
  final int subtotalCents, discountCents, totalCents;
  final String? approverName, mpesaCode;
  final PaymentMethod method;

  /// Cash handed over and change given. Null/0 for M-Pesa.
  final int? tenderedCents;
  final int changeCents;
}

class SalesService {
  SalesService(this._db, this._stock, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final StockService _stock;
  final DateTime Function() _now;

  static final _mpesaCode = RegExp(r'^[A-Z0-9]{8,12}$');

  /// Completes a sale in one transaction. Prices and batches are worked out
  /// again from current stock, so a stale screen can never oversell.
  Future<SaleReceipt> completeSale({
    required List<CartLine> lines,
    required int cashierId,
    int discountCents = 0,
    int? discountApprovedBy,
    required PaymentMethod method,
    int? cashTenderedCents,
    String? mpesaCode,
  }) async {
    if (lines.isEmpty) throw SaleRuleException('The cart is empty.');

    return _db.transaction(() async {
      final stock = {
        for (final s in await _stock.listStock()) s.medicine.id: s,
      };
      final quote = quoteCart(lines, stock);
      if (!quote.isValid) {
        final bad = quote.lines.firstWhere(
          (l) => !l.isValid,
          orElse: () => quote.lines.first,
        );
        throw SaleRuleException(
          bad.notSoldThisWay
              ? '${bad.medicine.name} is no longer sold that way. Remove it and add it again.'
              : 'Not enough ${bad.medicine.name} in stock. Check the quantity.',
        );
      }

      final subtotal = quote.subtotalCents;
      if (discountCents < 0 ||
          (discountCents > 0 && discountCents >= subtotal)) {
        throw SaleRuleException(
          'The discount must be less than the sale total.',
        );
      }
      User? approver;
      if (discountCents > 0) {
        approver = discountApprovedBy == null
            ? null
            : await (_db.select(_db.users)..where(
                    (u) =>
                        u.id.equals(discountApprovedBy) &
                        u.active.equals(true) &
                        (u.role.equalsValue(Role.owner) |
                            u.role.equalsValue(Role.clinician)),
                  ))
                  .getSingleOrNull();
        if (approver == null) {
          throw SaleRuleException(
            'A discount needs approval from the owner or a clinician.',
          );
        }
      }
      final total = subtotal - discountCents;

      String? code;
      int? tendered;
      var change = 0;
      if (method == PaymentMethod.mpesa) {
        code = mpesaCode?.trim().toUpperCase();
        if (code == null || !_mpesaCode.hasMatch(code)) {
          throw SaleRuleException(
            'Enter the M-Pesa transaction code from the message, '
            'for example QGH7K2LMNP.',
          );
        }
      } else {
        tendered = cashTenderedCents ?? total;
        if (tendered < total) {
          throw SaleRuleException(
            'The cash received is less than the total. '
            'Enter the amount the customer handed over.',
          );
        }
        change = tendered - total;
      }

      final now = _now();
      final receiptNo = await _nextReceiptNo(now);
      final saleId = await _db
          .into(_db.sales)
          .insert(
            SalesCompanion.insert(
              receiptNo: receiptNo,
              cashierId: cashierId,
              subtotalCents: subtotal,
              discountCents: Value(discountCents),
              discountAuthorisedBy: Value(approver?.id),
              totalCents: total,
              createdAt: Value(now),
            ),
          );

      for (final l in quote.lines) {
        for (final a in l.allocations) {
          await _db
              .into(_db.saleItems)
              .insert(
                SaleItemsCompanion.insert(
                  saleId: saleId,
                  medicineId: l.medicine.id,
                  batchId: a.batchId,
                  priceMode: l.line.mode,
                  qtyBaseUnits: a.baseQty,
                  lineTotalCents: a.totalCents,
                ),
              );
          await _db
              .into(_db.stockMovements)
              .insert(
                StockMovementsCompanion.insert(
                  batchId: a.batchId,
                  qtyDelta: -a.baseQty,
                  reason: MovementReason.sale,
                  saleId: Value(saleId),
                  createdBy: cashierId,
                  createdAt: Value(now),
                ),
              );
        }
      }
      // The payment records what was applied to the sale; change is not income.
      await _db
          .into(_db.payments)
          .insert(
            PaymentsCompanion.insert(
              saleId: saleId,
              method: method,
              amountCents: total,
              mpesaCode: Value(code),
              createdAt: Value(now),
            ),
          );

      final cashier = await (_db.select(
        _db.users,
      )..where((u) => u.id.equals(cashierId))).getSingle();
      return SaleReceipt(
        receiptNo: receiptNo,
        createdAt: now,
        cashierName: cashier.displayName,
        lines: [
          for (final l in quote.lines)
            ReceiptLine(
              name: l.medicine.name,
              count: l.line.count,
              mode: l.line.mode,
              baseQty: l.baseQty,
              baseUnit: l.medicine.baseUnitName,
              unitPriceCents: priceCents(l.medicine, l.line.mode)!,
              totalCents: l.totalCents,
            ),
        ],
        subtotalCents: subtotal,
        discountCents: discountCents,
        approverName: approver?.displayName,
        totalCents: total,
        method: method,
        mpesaCode: code,
        tenderedCents: tendered,
        changeCents: change,
      );
    });
  }

  /// R20261010-0001: date, then a daily sequence. Runs inside the sale
  /// transaction, so two sales can never take the same number.
  Future<String> _nextReceiptNo(DateTime now) async {
    final d =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
    final prefix = 'R$d-';
    final n = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM sales WHERE receipt_no LIKE ?',
          variables: [Variable<String>('$prefix%')],
          readsFrom: {_db.sales},
        )
        .getSingle();
    return '$prefix${(n.read<int>('n') + 1).toString().padLeft(4, '0')}';
  }
}
