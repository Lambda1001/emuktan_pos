import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/sales_admin_service.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/cart.dart';
import 'package:emuktan_pos/domain/returns.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;

void main() {
  group('refund arithmetic', () {
    test('no discount: net equals line total', () {
      expect(netLineTotals(lineTotals: [9000, 1000], discountCents: 0), [
        9000,
        1000,
      ]);
    });

    test('discount shares always add up exactly', () {
      final rng = Random(7);
      for (var n = 0; n < 500; n++) {
        final lines = List.generate(
          1 + rng.nextInt(5),
          (_) => 1 + rng.nextInt(50000),
        );
        final subtotal = lines.fold<int>(0, (s, x) => s + x);
        final discount = rng.nextInt(subtotal);
        final net = netLineTotals(lineTotals: lines, discountCents: discount);
        expect(net.fold<int>(0, (s, x) => s + x), subtotal - discount);
        for (var i = 0; i < lines.length; i++) {
          expect(net[i], lessThanOrEqualTo(lines[i]));
          expect(net[i], greaterThanOrEqualTo(0));
        }
      }
    });

    test('returning a line in pieces refunds exactly its net, never more', () {
      final rng = Random(11);
      for (var n = 0; n < 500; n++) {
        final sold = 2 + rng.nextInt(40);
        final net = 1 + rng.nextInt(100000);
        var returned = 0, refunded = 0;
        while (returned < sold) {
          final q = 1 + rng.nextInt(sold - returned);
          refunded += refundFor(
            netCents: net,
            soldQty: sold,
            qty: q,
            alreadyReturned: returned,
            alreadyRefunded: refunded,
          );
          returned += q;
        }
        expect(refunded, net);
      }
    });

    test('out-of-range quantities are refused', () {
      for (final q in [0, -1, 6]) {
        expect(
          () => refundFor(
            netCents: 1000,
            soldQty: 5,
            qty: q,
            alreadyReturned: 0,
            alreadyRefunded: 0,
          ),
          throwsArgumentError,
        );
      }
    });
  });

  group('void and return', () {
    late AppDatabase db;
    late AuthService auth;
    late StockService stock;
    late SalesService sales;
    late SalesAdminService admin;
    late User owner, clinician, cashier;
    late int med, batch;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      auth = AuthService(db, hasher: const PinHasher(iterations: 10));
      stock = StockService(db);
      sales = SalesService(db, stock);
      admin = SalesAdminService(db);
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
      med = await stock.createMedicine(
        const MedicineInput(
          name: 'Paracetamol 500mg',
          unitsPerStrip: 10,
          pricePerStripCents: 9000,
          pricePerUnitCents: 1000,
        ),
        userId: owner.id,
      );
      batch = await stock.receiveStock(
        medicineId: med,
        batchNumber: 'B1',
        expiry: DateTime(2099, 12, 31),
        qtyBaseUnits: 100,
        costPerUnitCents: 500,
        userId: owner.id,
      );
    });
    tearDown(() => db.close());

    Future<SaleReceipt> sell(int strips, {int discount = 0}) =>
        sales.completeSale(
          lines: [
            CartLine(medicineId: med, mode: PriceMode.strip, count: strips),
          ],
          cashierId: cashier.id,
          discountCents: discount,
          discountApprovedBy: discount > 0 ? owner.id : null,
          method: PaymentMethod.cash,
        );

    Future<int> saleId(SaleReceipt r) async => (await (db.select(
      db.sales,
    )..where((s) => s.receiptNo.equals(r.receiptNo))).getSingle()).id;

    test('void puts every item back and keeps the record', () async {
      final r = await sell(3);
      expect(await db.stockOnHand(batch), 70);
      final id = await saleId(r);

      await admin.voidSale(
        saleId: id,
        reason: 'Rung up twice',
        approverId: clinician.id,
        actingUserId: cashier.id,
      );

      expect(await db.stockOnHand(batch), 100);
      final d = (await admin.detail(id))!;
      expect(d.isVoided, isTrue);
      expect(d.sale.voidReason, 'Rung up twice');
      expect(d.voidedByName, 'Peter Njoroge');
      expect(d.canVoid, isFalse);
      expect(d.canReturn, isFalse);
      expect(await db.select(db.payments).get(), hasLength(1)); // record kept
    });

    test('void needs a reason and an owner or clinician approver', () async {
      final id = await saleId(await sell(1));
      for (final bad in [
        (cashier.id, 'Rung up twice'),
        (999, 'Rung up twice'),
        (owner.id, ' '),
      ]) {
        await expectLater(
          admin.voidSale(
            saleId: id,
            reason: bad.$2,
            approverId: bad.$1,
            actingUserId: cashier.id,
          ),
          throwsA(isA<SaleRuleException>()),
        );
      }
      expect(await db.stockOnHand(batch), 90); // nothing changed
    });

    test('cannot void twice', () async {
      final id = await saleId(await sell(1));
      await admin.voidSale(
        saleId: id,
        reason: 'mistake',
        approverId: owner.id,
        actingUserId: owner.id,
      );
      await expectLater(
        admin.voidSale(
          saleId: id,
          reason: 'again',
          approverId: owner.id,
          actingUserId: owner.id,
        ),
        throwsA(isA<SaleRuleException>()),
      );
      expect(await db.stockOnHand(batch), 100); // not restocked twice
    });

    test('partial return refunds what was paid and restocks', () async {
      final id = await saleId(await sell(3)); // 30 tablets, KES 270
      final line = (await admin.detail(id))!.lines.single;

      final refund = await admin.returnItems(
        saleId: id,
        qtyByItemId: {line.item.id: 10}, // one strip
        reason: 'Wrong medicine',
        approverId: owner.id,
        actingUserId: cashier.id,
        refundMethod: PaymentMethod.cash,
      );

      expect(refund, 9000);
      expect(await db.stockOnHand(batch), 80);
      final d = (await admin.detail(id))!;
      expect(d.refundedCents, 9000);
      expect(d.lines.single.remainingQty, 20);
      expect(d.canVoid, isFalse); // already part-returned
      expect(d.canReturn, isTrue);
    });

    test(
      'returning everything in pieces refunds exactly the total paid',
      () async {
        final r = await sell(3, discount: 1000); // total 26000
        final id = await saleId(r);
        final line = (await admin.detail(id))!.lines.single;
        var total = 0;
        for (final q in [7, 13, 10]) {
          total += await admin.returnItems(
            saleId: id,
            qtyByItemId: {line.item.id: q},
            reason: 'Customer changed mind',
            approverId: owner.id,
            actingUserId: owner.id,
            refundMethod: PaymentMethod.cash,
          );
        }
        expect(total, r.totalCents);
        expect(await db.stockOnHand(batch), 100);
        expect((await admin.detail(id))!.canReturn, isFalse);
      },
    );

    test('cannot return more than was sold or already returned', () async {
      final id = await saleId(await sell(1));
      final line = (await admin.detail(id))!.lines.single;
      Future<int> ret(int q) => admin.returnItems(
        saleId: id,
        qtyByItemId: {line.item.id: q},
        reason: 'x y z',
        approverId: owner.id,
        actingUserId: owner.id,
        refundMethod: PaymentMethod.cash,
      );
      await ret(6);
      await expectLater(ret(5), throwsA(isA<SaleRuleException>()));
      await expectLater(ret(0), throwsA(isA<SaleRuleException>()));
      expect(await db.stockOnHand(batch), 96);
    });

    test('damaged returns refund the customer but do not restock', () async {
      final id = await saleId(await sell(1));
      final line = (await admin.detail(id))!.lines.single;
      await admin.returnItems(
        saleId: id,
        qtyByItemId: {line.item.id: 10},
        reason: 'Packet damaged',
        approverId: owner.id,
        actingUserId: owner.id,
        refundMethod: PaymentMethod.mpesa,
        restock: false,
      );
      expect(await db.stockOnHand(batch), 90);
      final ret = await db.select(db.saleReturns).getSingle();
      expect(ret.restocked, isFalse);
      expect(ret.refundMethod, PaymentMethod.mpesa);
    });

    test('a voided sale cannot be returned', () async {
      final id = await saleId(await sell(1));
      final line = (await admin.detail(id))!.lines.single;
      await admin.voidSale(
        saleId: id,
        reason: 'mistake',
        approverId: owner.id,
        actingUserId: owner.id,
      );
      await expectLater(
        admin.returnItems(
          saleId: id,
          qtyByItemId: {line.item.id: 1},
          reason: 'x y z',
          approverId: owner.id,
          actingUserId: owner.id,
          refundMethod: PaymentMethod.cash,
        ),
        throwsA(isA<SaleRuleException>()),
      );
    });

    test(
      'recent sales list shows newest first, with refunds, and finds by receipt',
      () async {
        final a = await sell(1);
        final b = await sell(2);
        final idB = await saleId(b);
        final line = (await admin.detail(idB))!.lines.single;
        await admin.returnItems(
          saleId: idB,
          qtyByItemId: {line.item.id: 10},
          reason: 'Wrong one',
          approverId: owner.id,
          actingUserId: owner.id,
          refundMethod: PaymentMethod.cash,
        );

        final list = await admin.recentSales(since: DateTime(2000));
        expect(list.map((s) => s.sale.receiptNo), [b.receiptNo, a.receiptNo]);
        expect(list.first.refundedCents, 9000);
        expect(list.first.cashierName, 'Jane Doe');
        expect(list.first.method, PaymentMethod.cash);

        final found = await admin.recentSales(
          since: DateTime(2100),
          receiptQuery: a.receiptNo.substring(a.receiptNo.length - 4),
        );
        expect(found, isNotEmpty);
      },
    );
  });

  test(
    'a version 1 database upgrades to version 2 and keeps its data',
    () async {
      final dir = Directory.systemTemp.createTempSync('emuktan_mig_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File(p.join(dir.path, 'v1.db'));

      // Build a current database, then turn it back into a v1 file: no
      // sale_returns table, user_version 1.
      var db = AppDatabase(NativeDatabase(file));
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              username: 'owner',
              displayName: 'Owner',
              role: Role.owner,
              secretHash: 'h',
              secretSalt: 's',
            ),
          );
      await db.close();
      final conn = raw.sqlite3.open(file.path);
      conn.execute('DROP TABLE sale_returns');
      conn.execute('DROP TABLE held_sales'); // also newer than version 1
      conn.execute('PRAGMA user_version = 1');
      conn.close();

      db = AppDatabase(NativeDatabase(file));
      expect(await db.select(db.saleReturns).get(), isEmpty); // table is back
      expect(await db.select(db.heldSales).get(), isEmpty);
      expect((await db.select(db.users).get()).single.username, 'owner');
      final v = await db.customSelect('PRAGMA user_version').getSingle();
      expect(v.data.values.first, AppDatabase.currentSchemaVersion);
      await db.close();
    },
  );
}
