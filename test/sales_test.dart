import 'package:drift/native.dart';
import 'package:emuktan_pos/config/app_config.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/cart.dart';
import 'package:emuktan_pos/domain/receipt.dart';
import 'package:emuktan_pos/domain/stock_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;
  late StockService stock;
  late SalesService sales;
  late User owner, clinician, cashier;
  late int med;
  final now = DateTime(2026, 10, 10, 14, 32);

  // Paracetamol: strip of 10, pack of 100. Pack 800, strip 90, single 10.
  const para = MedicineInput(
    name: 'Paracetamol 500mg',
    baseUnitName: 'tablet',
    unitsPerStrip: 10,
    unitsPerPack: 100,
    pricePerPackCents: 80000,
    pricePerStripCents: 9000,
    pricePerUnitCents: 1000,
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    stock = StockService(db, clock: () => now);
    sales = SalesService(db, stock, clock: () => now);
    owner = await auth.createUser(
      displayName: 'Wanjiru Kamau',
      role: Role.owner,
      pin: '4821',
    );
    clinician = await auth.createUser(
      displayName: 'Peter Njoroge',
      role: Role.clinician,
      pin: '8642',
    );
    cashier = await auth.createUser(
      displayName: 'Jane Doe',
      role: Role.cashier,
      pin: '1357',
    );
    med = await stock.createMedicine(para, userId: owner.id);
  });
  tearDown(() => db.close());

  Future<int> receive(
    String batch,
    DateTime? expiry,
    int qty, {
    int cost = 500,
  }) => stock.receiveStock(
    medicineId: med,
    batchNumber: batch,
    expiry: expiry,
    qtyBaseUnits: qty,
    costPerUnitCents: cost,
    userId: owner.id,
  );

  Future<Map<int, MedicineStock>> stockMap() async => {
    for (final s in await stock.listStock()) s.medicine.id: s,
  };

  CartLine line(PriceMode mode, int count) =>
      CartLine(medicineId: med, mode: mode, count: count);

  group('pricing and batch allocation', () {
    test('line total is count x price, base quantity is converted', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      final q = quoteCart([line(PriceMode.strip, 3)], await stockMap());
      expect(q.lines.single.baseQty, 30);
      expect(q.lines.single.totalCents, 27000);
      expect(q.subtotalCents, 27000);
      expect(q.isValid, isTrue);
    });

    test('takes the batch that expires first', () async {
      await receive('LATE', DateTime(2028, 6, 30), 100);
      await receive('SOON', DateTime(2027, 3, 31), 100);
      final q = quoteCart([line(PriceMode.unit, 5)], await stockMap());
      expect(q.lines.single.allocations.single.batchNumber, 'SOON');
    });

    test(
      'spills into the next batch, and the parts add up to the line total',
      () async {
        await receive('SOON', DateTime(2027, 3, 31), 25);
        await receive('LATE', DateTime(2028, 6, 30), 100);
        // 4 strips = 40 tablets for 360: 25 from SOON, 15 from LATE.
        final q = quoteCart([line(PriceMode.strip, 4)], await stockMap());
        final a = q.lines.single.allocations;
        expect(a.map((x) => x.batchNumber), ['SOON', 'LATE']);
        expect(a.map((x) => x.baseQty), [25, 15]);
        expect(a.fold<int>(0, (s, x) => s + x.totalCents), 36000);
      },
    );

    test(
      'two lines of one medicine share batches without double-counting',
      () async {
        await receive('B1', DateTime(2027, 12, 31), 12);
        final q = quoteCart([
          line(PriceMode.strip, 1), // 10
          line(PriceMode.unit, 3), // only 2 left
        ], await stockMap());
        expect(q.lines[0].isValid, isTrue);
        expect(q.lines[1].shortBy, 1);
        expect(q.isValid, isFalse);
      },
    );

    test(
      'expired stock is used only as a last resort and is flagged',
      () async {
        await receive('OLD', DateTime(2026, 10, 20), 50); // valid when received
        await receive('NEW', DateTime(2028, 1, 31), 30);
        final later = DateTime(2026, 11, 5); // OLD has now expired
        final s = {
          for (final x in await StockService(
            db,
            clock: () => later,
          ).listStock())
            x.medicine.id: x,
        };

        var q = quoteCart([line(PriceMode.unit, 20)], s);
        expect(q.lines.single.allocations.single.batchNumber, 'NEW');
        expect(q.hasExpired, isFalse);

        q = quoteCart([line(PriceMode.unit, 40)], s); // NEW has 30
        expect(q.lines.single.allocations.map((a) => a.batchNumber), [
          'NEW',
          'OLD',
        ]);
        expect(q.hasExpired, isTrue);
        expect(q.isValid, isTrue); // warn only, not blocked
      },
    );

    test('a way of selling that is no longer offered is invalid', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      await stock.updateMedicine(
        med,
        const MedicineInput(name: 'Paracetamol 500mg', pricePerUnitCents: 1000),
      );
      final q = quoteCart([line(PriceMode.pack, 1)], await stockMap());
      expect(q.lines.single.notSoldThisWay, isTrue);
      expect(q.isValid, isFalse);
    });
  });

  group('completing a sale', () {
    Future<SaleReceipt> sell(
      List<CartLine> lines, {
      int discount = 0,
      int? approver,
      PaymentMethod method = PaymentMethod.cash,
      int? tendered,
      String? code,
    }) => sales.completeSale(
      lines: lines,
      cashierId: cashier.id,
      discountCents: discount,
      discountApprovedBy: approver,
      method: method,
      cashTenderedCents: tendered,
      mpesaCode: code,
    );

    test('cash sale: records everything and reduces stock', () async {
      final b = await receive('B1', DateTime(2027, 12, 31), 500);
      final r = await sell([line(PriceMode.strip, 3)], tendered: 30000);

      expect(r.totalCents, 27000);
      expect(r.changeCents, 3000);
      expect(r.receiptNo, 'R20261010-0001');
      expect(await db.stockOnHand(b), 470);

      final sale = await db.select(db.sales).getSingle();
      expect(sale.totalCents, 27000);
      expect(sale.cashierId, cashier.id);
      final pay = await db.select(db.payments).getSingle();
      expect(pay.amountCents, 27000); // change is not income
      expect(pay.method, PaymentMethod.cash);
      final items = await db.select(db.saleItems).get();
      expect(items.single.qtyBaseUnits, 30);
      final mv = await (db.select(
        db.stockMovements,
      )..where((m) => m.reason.equalsValue(MovementReason.sale))).getSingle();
      expect(mv.qtyDelta, -30);
      expect(mv.saleId, sale.id);
    });

    test('receipt numbers count up through the day', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      final a = await sell([line(PriceMode.unit, 1)]);
      final b = await sell([line(PriceMode.unit, 1)]);
      expect([a.receiptNo, b.receiptNo], ['R20261010-0001', 'R20261010-0002']);
    });

    test(
      'a sale spanning two batches writes a row and movement for each',
      () async {
        final soon = await receive('SOON', DateTime(2027, 3, 31), 25);
        final late = await receive('LATE', DateTime(2028, 6, 30), 100);
        await sell([line(PriceMode.strip, 4)]);
        expect(await db.stockOnHand(soon), 0);
        expect(await db.stockOnHand(late), 85);
        expect(await db.select(db.saleItems).get(), hasLength(2));
      },
    );

    test('not enough stock: refused and nothing is written', () async {
      final b = await receive('B1', DateTime(2027, 12, 31), 5);
      await expectLater(
        sell([line(PriceMode.strip, 1)]),
        throwsA(isA<SaleRuleException>()),
      );
      expect(await db.stockOnHand(b), 5);
      expect(await db.select(db.sales).get(), isEmpty);
    });

    test('cash short of the total is refused', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      await expectLater(
        sell([line(PriceMode.strip, 1)], tendered: 5000),
        throwsA(isA<SaleRuleException>()),
      );
      expect(await db.select(db.sales).get(), isEmpty);
    });

    test('discount needs an owner or clinician approver', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      for (final who in [null, cashier.id, 999]) {
        await expectLater(
          sell([line(PriceMode.strip, 1)], discount: 1000, approver: who),
          throwsA(isA<SaleRuleException>()),
          reason: 'approver $who',
        );
      }
      final r = await sell(
        [line(PriceMode.strip, 1)],
        discount: 1000,
        approver: clinician.id,
      );
      expect(r.totalCents, 8000);
      expect(r.approverName, 'Peter Njoroge');
      final sale = await db.select(db.sales).getSingle();
      expect(sale.discountCents, 1000);
      expect(sale.discountAuthorisedBy, clinician.id);
      expect(sale.subtotalCents, 9000);
    });

    test('the owner can approve a discount', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      final r = await sell(
        [line(PriceMode.strip, 1)],
        discount: 500,
        approver: owner.id,
      );
      expect(r.totalCents, 8500);
    });

    test('a deactivated approver no longer counts', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      await auth.setActive(clinician.id, false, actingUserId: owner.id);
      await expectLater(
        sell([line(PriceMode.strip, 1)], discount: 500, approver: clinician.id),
        throwsA(isA<SaleRuleException>()),
      );
    });

    test('discount cannot be as large as the whole sale', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      await expectLater(
        sell([line(PriceMode.strip, 1)], discount: 9000, approver: owner.id),
        throwsA(isA<SaleRuleException>()),
      );
    });

    test('M-Pesa needs a valid code, stored upper-case', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      for (final bad in [null, '', 'abc', 'has space1']) {
        await expectLater(
          sell(
            [line(PriceMode.unit, 1)],
            method: PaymentMethod.mpesa,
            code: bad,
          ),
          throwsA(isA<SaleRuleException>()),
          reason: '$bad',
        );
      }
      final r = await sell(
        [line(PriceMode.unit, 1)],
        method: PaymentMethod.mpesa,
        code: 'qgh7k2lmnp',
      );
      expect(r.mpesaCode, 'QGH7K2LMNP');
      expect(
        (await db.select(db.payments).getSingle()).mpesaCode,
        'QGH7K2LMNP',
      );
    });

    test('expired stock can be sold (warn only)', () async {
      final b = await receive('OLD', DateTime(2026, 10, 20), 50);
      final later = DateTime(2026, 11, 5);
      final svc = SalesService(
        db,
        StockService(db, clock: () => later),
        clock: () => later,
      );
      final r = await svc.completeSale(
        lines: [line(PriceMode.unit, 10)],
        cashierId: cashier.id,
        method: PaymentMethod.cash,
      );
      expect(r.totalCents, 10000);
      expect(await db.stockOnHand(b), 40);
    });

    test('empty cart is refused', () async {
      await expectLater(sell([]), throwsA(isA<SaleRuleException>()));
    });
  });

  group('discount approver check', () {
    test('finds the owner or clinician by PIN, not the cashier', () async {
      expect((await auth.verifyApprover('4821'))?.id, owner.id);
      expect((await auth.verifyApprover('8642'))?.id, clinician.id);
      expect(await auth.verifyApprover('1357'), isNull); // cashier's PIN
      expect(await auth.verifyApprover('0000'), isNull);
    });

    test('repeated wrong guesses lock the approval sheet', () async {
      for (var i = 0; i < AppConfig.pinMaxAttempts; i++) {
        expect(await auth.verifyApprover('0000'), isNull);
      }
      await expectLater(
        auth.verifyApprover('4821'),
        throwsA(isA<PinLockedException>()),
      );
    });
  });

  group('receipt text', () {
    test('fits 48 columns and shows the key facts', () async {
      await receive('B1', DateTime(2027, 12, 31), 500);
      final r = await sales.completeSale(
        lines: [line(PriceMode.strip, 2), line(PriceMode.unit, 3)],
        cashierId: cashier.id,
        discountCents: 1000,
        discountApprovedBy: owner.id,
        method: PaymentMethod.cash,
        cashTenderedCents: 20000,
      );
      final text = renderReceipt(r);
      for (final l in text.split('\n')) {
        expect(l.length, lessThanOrEqualTo(ReceiptConfig.charsPerLine));
      }
      expect(text, contains('R20261010-0001'));
      expect(text, contains('Served by Jane Doe'));
      expect(text, contains('2 strips x KES 90.00'));
      expect(text, contains('KES 180.00'));
      expect(text, contains('Discount'));
      expect(text, contains('-KES 10.00'));
      expect(text, contains('TOTAL'));
      expect(text, contains('KES 200.00')); // 180 + 30 - 10 = 200
      expect(text, contains('Change'));
      expect(text, contains('10 Oct 2026  14:32'));
    });

    test('long medicine names and M-Pesa receipts stay in width', () async {
      final long = await stock.createMedicine(
        const MedicineInput(
          name: 'Amoxicillin + Clavulanic Acid 625mg Film-Coated Tablets',
          pricePerUnitCents: 12000,
        ),
        userId: owner.id,
      );
      await stock.receiveStock(
        medicineId: long,
        batchNumber: 'X',
        expiry: DateTime(2028, 1, 31),
        qtyBaseUnits: 50,
        costPerUnitCents: 8000,
        userId: owner.id,
      );
      final r = await sales.completeSale(
        lines: [CartLine(medicineId: long, mode: PriceMode.unit, count: 14)],
        cashierId: cashier.id,
        method: PaymentMethod.mpesa,
        mpesaCode: 'QGH7K2LMNP',
      );
      final text = renderReceipt(r);
      expect(text, contains('QGH7K2LMNP'));
      expect(text, contains('M-Pesa'));
      for (final l in text.split('\n')) {
        expect(
          l.length,
          lessThanOrEqualTo(ReceiptConfig.charsPerLine),
          reason: l,
        );
      }
      // The name wraps onto a second line instead of being cut off.
      expect(text, contains('Film-Coated\nTablets'));
    });
  });
}
