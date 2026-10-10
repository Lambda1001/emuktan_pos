import 'package:drift/native.dart';
import 'package:emuktan_pos/core/format.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/stock_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatting', () {
    test('money shows cents only when non-zero, or always when asked', () {
      expect(formatKes(132000), 'KES 1,320');
      expect(formatKes(132050), 'KES 1,320.50');
      expect(formatKes(132000, alwaysCents: true), 'KES 1,320.00');
      expect(formatKes(35), 'KES 0.35');
      expect(formatKes(100000000), 'KES 1,000,000');
    });

    test('money input parsing', () {
      expect(parseKes('1,320'), 132000);
      expect(parseKes('12.5'), 1250);
      expect(parseKes('0.35'), 35);
      expect(parseKes(' 7 '), 700);
      for (final bad in ['', 'abc', '1.234', '-5', '1..2', 'KES 5']) {
        expect(parseKes(bad), isNull, reason: bad);
      }
    });

    test('dates and expiry', () {
      expect(formatDate(DateTime(2026, 10, 7)), '07 Oct 2026');
      expect(formatExpiry(DateTime(2026, 12, 31)), 'Dec 2026');
    });

    test('expiry input becomes the last day of the month', () {
      expect(parseExpiry('12/2026'), DateTime(2026, 12, 31));
      expect(parseExpiry('2/28'), DateTime(2028, 2, 29)); // leap year
      expect(parseExpiry('02-2027'), DateTime(2027, 2, 28));
      for (final bad in ['', '13/2026', '0/2026', 'Dec 2026', '12/1999']) {
        expect(parseExpiry(bad), isNull, reason: bad);
      }
    });

    test('quantities carry their unit', () {
      expect(quantityText(842, 'tablet'), '842 tablets');
      expect(quantityText(1, 'tablet'), '1 tablet');
      expect(quantityText(250, 'ml'), '250 ml');
      expect(quantityText(1200, 'tablet'), '1,200 tablets');
      expect(quantityText(3, 'box'), '3 boxes');
    });
  });

  group('expiry and low-stock rules', () {
    final now = DateTime(2026, 10, 10, 14, 30);

    test('expired only from the day after the expiry date', () {
      expect(
        expiryState(DateTime(2026, 10, 10), now),
        isNot(ExpiryState.expired),
      );
      expect(expiryState(DateTime(2026, 10, 9), now), ExpiryState.expired);
      expect(expiryState(null, now), ExpiryState.none);
    });

    test('expires soon inside the warning window, ok beyond it', () {
      expect(expiryState(DateTime(2026, 12, 31), now), ExpiryState.soon);
      expect(expiryState(DateTime(2027, 6, 30), now), ExpiryState.ok);
    });

    test('low stock needs a reorder level; 0 means not set', () {
      expect(isLowStock(sellable: 5, threshold: 0), isFalse);
      expect(isLowStock(sellable: 10, threshold: 10), isTrue);
      expect(isLowStock(sellable: 11, threshold: 10), isFalse);
    });
  });

  group('StockService', () {
    late AppDatabase db;
    late StockService stock;
    late int uid;
    var now = DateTime(2026, 10, 10);

    const paracetamol = MedicineInput(
      name: 'Paracetamol 500mg',
      barcode: '6001',
      baseUnitName: 'tablet',
      unitsPerStrip: 10,
      unitsPerPack: 100,
      pricePerPackCents: 80000,
      pricePerStripCents: 9000,
      pricePerUnitCents: 1000,
      lowStockThreshold: 200,
    );

    setUp(() async {
      now = DateTime(2026, 10, 10);
      db = AppDatabase(NativeDatabase.memory());
      stock = StockService(db, clock: () => now);
      uid = await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              username: 'owner',
              displayName: 'Owner',
              role: Role.owner,
              secretHash: 'x',
              secretSalt: 'y',
            ),
          );
    });
    tearDown(() => db.close());

    Future<int> receive(
      int med,
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
      userId: uid,
    );

    test('creates a medicine and lists it with no stock', () async {
      await stock.createMedicine(paracetamol, userId: uid);
      final list = await stock.listStock();
      expect(list.single.medicine.name, 'Paracetamol 500mg');
      expect(list.single.onHand, 0);
      expect(offeredModes(list.single.medicine), [
        PriceMode.pack,
        PriceMode.strip,
        PriceMode.unit,
      ]);
    });

    test('medicine validation gives plain messages', () async {
      Future<void> bad(MedicineInput i, String text) => expectLater(
        stock.createMedicine(i, userId: uid),
        throwsA(
          isA<StockRuleException>().having(
            (e) => e.message,
            'message',
            contains(text),
          ),
        ),
      );

      await bad(const MedicineInput(name: 'x', pricePerUnitCents: 100), 'name');
      await bad(
        const MedicineInput(name: 'Amoxil'),
        'at least one selling price',
      );
      await bad(
        const MedicineInput(name: 'Amoxil', pricePerUnitCents: 0),
        'more than zero',
      );
      await bad(
        const MedicineInput(name: 'Amoxil', pricePerPackCents: 500),
        'how many are in a pack',
      );
      await bad(
        const MedicineInput(name: 'Amoxil', pricePerStripCents: 500),
        'how many are in a strip',
      );
      await bad(
        const MedicineInput(
          name: 'Amoxil',
          unitsPerStrip: 10,
          unitsPerPack: 25,
          pricePerUnitCents: 100,
        ),
        'whole number of strips',
      );
      await bad(
        const MedicineInput(
          name: 'Amoxil',
          pricePerUnitCents: 100,
          lowStockThreshold: -1,
        ),
        'negative',
      );
    });

    test(
      'duplicate name (any case) and duplicate barcode are refused',
      () async {
        await stock.createMedicine(paracetamol, userId: uid);
        await expectLater(
          stock.createMedicine(
            const MedicineInput(
              name: 'paracetamol 500MG',
              pricePerUnitCents: 100,
            ),
            userId: uid,
          ),
          throwsA(isA<StockRuleException>()),
        );
        await expectLater(
          stock.createMedicine(
            const MedicineInput(
              name: 'Other',
              barcode: '6001',
              pricePerUnitCents: 100,
            ),
            userId: uid,
          ),
          throwsA(isA<StockRuleException>()),
        );
      },
    );

    test('editing keeps its own name and barcode without a clash', () async {
      final id = await stock.createMedicine(paracetamol, userId: uid);
      await stock.updateMedicine(
        id,
        const MedicineInput(
          name: 'Paracetamol 500mg',
          barcode: '6001',
          baseUnitName: 'tablet',
          pricePerUnitCents: 1200,
          lowStockThreshold: 300,
        ),
      );
      final m = (await stock.listStock()).single.medicine;
      expect(m.pricePerUnitCents, 1200);
      expect(m.lowStockThreshold, 300);
      expect(m.pricePerPackCents, isNull);
    });

    test(
      'receiving creates a batch and a ledger entry; stock is the sum',
      () async {
        final med = await stock.createMedicine(paracetamol, userId: uid);
        final batch = await receive(med, 'B1', DateTime(2027, 12, 31), 500);
        await receive(med, 'B1', DateTime(2027, 12, 31), 250); // top-up
        expect(await db.stockOnHand(batch), 750);
        final s = (await stock.listStock()).single;
        expect(s.onHand, 750);
        expect(s.batches.single.batch.costPerUnitCents, 500);
      },
    );

    test('cost is recorded per unit on the batch', () async {
      final med = await stock.createMedicine(paracetamol, userId: uid);
      final id = await receive(
        med,
        'B1',
        DateTime(2027, 12, 31),
        100,
        cost: 350,
      );
      final b = await (db.select(
        db.batches,
      )..where((x) => x.id.equals(id))).getSingle();
      expect(b.costPerUnitCents, 350);
    });

    test(
      'same batch number with different expiry or cost is refused',
      () async {
        final med = await stock.createMedicine(paracetamol, userId: uid);
        await receive(med, 'B1', DateTime(2027, 12, 31), 100);
        await expectLater(
          receive(med, 'B1', DateTime(2028, 1, 31), 100),
          throwsA(
            isA<StockRuleException>().having(
              (e) => e.message,
              'm',
              contains('expiry'),
            ),
          ),
        );
        await expectLater(
          receive(med, 'B1', DateTime(2027, 12, 31), 100, cost: 999),
          throwsA(
            isA<StockRuleException>().having(
              (e) => e.message,
              'm',
              contains('cost'),
            ),
          ),
        );
        expect(
          (await stock.listStock()).single.onHand,
          100,
        ); // nothing half-applied
      },
    );

    test('receiving rejects bad input and expired stock', () async {
      final med = await stock.createMedicine(paracetamol, userId: uid);
      for (final f in <Future<int> Function()>[
        () => receive(med, '  ', DateTime(2027, 12, 31), 10),
        () => receive(med, 'B1', DateTime(2027, 12, 31), 0),
        () => receive(med, 'B1', DateTime(2027, 12, 31), 10, cost: -1),
        () => receive(med, 'B1', DateTime(2026, 9, 30), 10), // already expired
        () => receive(999, 'B1', DateTime(2027, 12, 31), 10),
      ]) {
        await expectLater(f(), throwsA(isA<StockRuleException>()));
      }
      expect(await db.select(db.batches).get(), isEmpty);
    });

    test('inactive medicines cannot be received', () async {
      final med = await stock.createMedicine(paracetamol, userId: uid);
      await stock.setMedicineActive(med, false);
      await expectLater(
        receive(med, 'B1', DateTime(2027, 12, 31), 10),
        throwsA(isA<StockRuleException>()),
      );
      expect(await stock.listStock(), isEmpty);
      expect(await stock.listStock(includeInactive: true), hasLength(1));
    });

    test('low stock counts only sellable (non-expired) stock', () async {
      final med = await stock.createMedicine(
        paracetamol,
        userId: uid,
      ); // level 200
      await receive(med, 'OLD', DateTime(2026, 11, 30), 150);
      await receive(med, 'NEW', DateTime(2028, 1, 31), 100);
      var s = (await stock.listStock()).single;
      expect(s.onHand, 250);
      expect(s.isLow, isFalse);

      now = DateTime(2026, 12, 15); // OLD has now expired
      s = (await stock.listStock()).single;
      expect(s.expiredQty, 150);
      expect(s.hasExpired, isTrue);
      expect(s.sellable, 100);
      expect(s.isLow, isTrue);
    });

    test(
      'next batch to sell is the earliest non-expired, no-expiry last',
      () async {
        final med = await stock.createMedicine(paracetamol, userId: uid);
        await receive(med, 'NOEXP', null, 10);
        await receive(med, 'LATE', DateTime(2028, 6, 30), 10);
        await receive(med, 'SOON', DateTime(2027, 3, 31), 10);
        await receive(med, 'GONE', DateTime(2026, 10, 31), 10);
        now = DateTime(2026, 11, 5); // GONE expired
        final s = (await stock.listStock()).single;
        expect(s.nextBatchToSell!.batch.batchNumber, 'SOON');
        expect(s.nextExpiry, DateTime(2027, 3, 31));
        expect(s.batches.map((b) => b.batch.batchNumber), [
          'GONE',
          'SOON',
          'LATE',
          'NOEXP',
        ]);
      },
    );

    group('adjusting', () {
      late int med, batch;
      setUp(() async {
        med = await stock.createMedicine(paracetamol, userId: uid);
        batch = await receive(med, 'B1', DateTime(2027, 12, 31), 100);
      });

      Future<void> adjust(
        int delta,
        MovementReason r, [
        String note = 'broken pack',
      ]) => stock.adjustStock(
        batchId: batch,
        qtyDelta: delta,
        reason: r,
        note: note,
        userId: uid,
      );

      test('write-off removes stock and keeps the reason', () async {
        await adjust(-30, MovementReason.writeOffDamaged);
        expect(await db.stockOnHand(batch), 70);
        final m =
            await (db.select(db.stockMovements)..where(
                  (x) => x.reason.equalsValue(MovementReason.writeOffDamaged),
                ))
                .getSingle();
        expect(m.note, 'broken pack');
        expect(m.createdBy, uid);
      });

      test('a correction can add or remove', () async {
        await adjust(5, MovementReason.adjustment, 'miscounted');
        await adjust(-2, MovementReason.adjustment, 'miscounted');
        expect(await db.stockOnHand(batch), 103);
      });

      test(
        'cannot go below zero, and nothing is written when refused',
        () async {
          await expectLater(
            adjust(-101, MovementReason.writeOffExpired),
            throwsA(
              isA<StockRuleException>().having(
                (e) => e.message,
                'm',
                contains('100 left'),
              ),
            ),
          );
          expect(await db.stockOnHand(batch), 100);
        },
      );

      test(
        'needs a reason, a non-zero change, and write-offs only remove',
        () async {
          await expectLater(
            adjust(-1, MovementReason.adjustment, ' '),
            throwsA(isA<StockRuleException>()),
          );
          await expectLater(
            adjust(0, MovementReason.adjustment),
            throwsA(isA<StockRuleException>()),
          );
          await expectLater(
            adjust(5, MovementReason.writeOffDamaged),
            throwsA(isA<StockRuleException>()),
          );
          await expectLater(
            adjust(-1, MovementReason.sale),
            throwsA(isA<StockRuleException>()),
          );
        },
      );
    });
  });
}
