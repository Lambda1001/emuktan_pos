import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/backup_service.dart';
import 'package:emuktan_pos/data/backup_upload.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/mpesa_stk_service.dart';
import 'package:emuktan_pos/data/patient_service.dart';
import 'package:emuktan_pos/data/sales_admin_service.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/sync_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/cart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Pushes real app data to a running dashboard. Skipped unless
/// EMUKTAN_LIVE_URL and EMUKTAN_LIVE_KEY are set (a manual end-to-end check).
void main() {
  final url = Platform.environment['EMUKTAN_LIVE_URL'];
  final key = Platform.environment['EMUKTAN_LIVE_KEY'];
  final skip = (url == null || key == null)
      ? 'set EMUKTAN_LIVE_URL and EMUKTAN_LIVE_KEY'
      : false;

  test(
    'real sales, discount, void, return and patient reach the dashboard',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(db, hasher: const PinHasher(iterations: 10));
      final stock = StockService(db);
      final sales = SalesService(db, stock);
      final admin = SalesAdminService(db);
      final patients = PatientService(db);
      final sync = SyncService(db);

      final owner = await auth.createUser(
        displayName: 'Wanjiru Kamau',
        role: Role.owner,
        pin: '4821',
      );
      final cashier = await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '1357',
      );
      final med = await stock.createMedicine(
        const MedicineInput(
          name: 'Paracetamol 500mg',
          baseUnitName: 'tablet',
          unitsPerStrip: 10,
          unitsPerPack: 100,
          pricePerPackCents: 80000,
          pricePerStripCents: 9000,
          pricePerUnitCents: 1000,
        ),
        userId: owner.id,
      );
      await stock.receiveStock(
        medicineId: med,
        batchNumber: 'B1',
        expiry: DateTime(2027, 12, 31),
        qtyBaseUnits: 500,
        costPerUnitCents: 500,
        userId: owner.id,
      );

      final patient = await patients.register(
        const PatientInput(fullName: 'Secret Patient', phone: '0712345678'),
        userId: owner.id,
      );
      await patients.recordVisit(
        patient.id,
        userId: owner.id,
        notes: 'private',
      );

      List<CartLine> strips(int n) => [
        CartLine(medicineId: med, mode: PriceMode.strip, count: n),
      ];
      // A: 2 strips cash, patient-linked, 18000.   B: 1 strip M-Pesa, 9000.
      // C: 1 strip cash with 1000 discount, 8000.  D: 3 tablets cash 3000, voided.
      await sales.completeSale(
        lines: strips(2),
        cashierId: cashier.id,
        method: PaymentMethod.cash,
        cashTenderedCents: 20000,
        patientId: patient.id,
      );
      await sales.completeSale(
        lines: strips(1),
        cashierId: cashier.id,
        method: PaymentMethod.mpesa,
        mpesaCode: 'SHK1ABC234',
      );
      await sales.completeSale(
        lines: strips(1),
        cashierId: cashier.id,
        discountCents: 1000,
        discountApprovedBy: owner.id,
        method: PaymentMethod.cash,
        cashTenderedCents: 10000,
      );
      await sales.completeSale(
        lines: [CartLine(medicineId: med, mode: PriceMode.unit, count: 3)],
        cashierId: cashier.id,
        method: PaymentMethod.cash,
        cashTenderedCents: 3000,
      );

      final all = await (db.select(
        db.sales,
      )..orderBy([(s) => OrderingTerm.asc(s.id)])).get();
      await admin.voidSale(
        saleId: all[3].id,
        reason: 'Customer left',
        approverId: owner.id,
        actingUserId: owner.id,
      );
      final itemA = await (db.select(
        db.saleItems,
      )..where((i) => i.saleId.equals(all[0].id))).getSingle();
      await admin.returnItems(
        saleId: all[0].id,
        qtyByItemId: {itemA.id: 10},
        reason: 'Wrong strength',
        approverId: owner.id,
        actingUserId: owner.id,
        refundMethod: PaymentMethod.cash,
      );

      await sync.configure(url: url!, key: key!);
      final first = await sync.syncNow();
      expect(first.message, isNull);
      expect(first.outcome, SyncOutcome.ok);
      expect(first.sent, greaterThan(10));
      expect((await sync.status()).pending, 0);

      final second = await sync.syncNow(); // heartbeat
      expect(second.outcome, SyncOutcome.ok);
      expect(second.sent, 0);
    },
    skip: skip,
  );

  test(
    'a real encrypted backup is stored byte for byte on the server',
    () async {
      final root = Directory.systemTemp.createTempSync('emuktan_live_');
      addTearDown(() => root.deleteSync(recursive: true));
      final data = Directory(p.join(root.path, 'data'))..createSync();
      final dbKey = Uint8List.fromList(
        List.generate(32, (i) => (i * 7 + 3) & 0xff),
      );
      final db = AppDatabase.encrypted(
        File(p.join(data.path, 'emuktan.db')),
        dbKey,
      );
      addTearDown(db.close);
      await db
          .into(db.users)
          .insert(
            UsersCompanion.insert(
              username: 'wanjiru',
              displayName: 'Wanjiru Kamau',
              role: Role.owner,
              secretHash: 'h',
              secretSalt: 's',
            ),
          );
      final backups = BackupService(db, data, dbKey);
      await backups.setFolder(p.join(root.path, 'usb'));
      final sync = SyncService(db);
      await sync.configure(url: url!, key: key!);
      final uploader = BackupUploader(db, backups, sync);

      final made = await backups.backupNow();
      final r = await uploader.uploadLatest();
      expect(r.message, isNull);
      expect(r.outcome, UploadOutcome.sent);
      expect((await uploader.status()).error, isNull);
      final copy = Platform.environment['EMUKTAN_LIVE_COPY'];
      if (copy != null) made.file.copySync(copy);
    },
    skip: skip,
  );

  // Needs the dashboard running with BUNI_DRIVER=fake (the simulator: it answers
  // after a few seconds; a phone ending 1111 cancels, 3333 never answers).
  test(
    'an M-Pesa prompt is requested, paid, used on a sale and synced',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final auth = AuthService(db, hasher: const PinHasher(iterations: 10));
      final stock = StockService(db);
      final sales = SalesService(db, stock);
      final sync = SyncService(db);
      final stk = MpesaStkService(sync);

      final owner = await auth.createUser(
        displayName: 'Wanjiru Kamau',
        role: Role.owner,
        pin: '4821',
      );
      final cashier = await auth.createUser(
        displayName: 'Jane Doe',
        role: Role.cashier,
        pin: '1357',
      );
      final med = await stock.createMedicine(
        const MedicineInput(
          name: 'Paracetamol 500mg',
          baseUnitName: 'tablet',
          unitsPerStrip: 10,
          pricePerStripCents: 9000,
          pricePerUnitCents: 1000,
        ),
        userId: owner.id,
      );
      await stock.receiveStock(
        medicineId: med,
        batchNumber: 'B1',
        expiry: DateTime(2027, 12, 31),
        qtyBaseUnits: 100,
        costPerUnitCents: 500,
        userId: owner.id,
      );

      await sync.configure(url: url!, key: key!);
      await sync.testConnection(url: url, key: key);
      expect(
        await stk.available(),
        isTrue,
        reason: 'server has BUNI_DRIVER on',
      );

      Future<StkStatus> ask(String phone) async {
        final id = stk.newRequestId();
        var s = await stk.start(
          requestId: id,
          amountCents: 9000,
          phone: phone,
          reference: 'R-LIVE',
        );
        expect(s.state, StkState.pending);
        expect(s.phone, isNot(contains('0712345678')));
        for (var i = 0; i < 12 && s.state == StkState.pending; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          s = await stk.check(id);
        }
        return s;
      }

      // The customer cancels.
      final cancelled = await ask('0700001111');
      expect(cancelled.state, StkState.cancelled);

      // The customer pays.
      final paid = await ask('0712345678');
      expect(paid.state, StkState.success);
      expect(paid.receipt, matches(RegExp(r'^SIM[A-Z0-9]{7}$')));

      // Sell with the confirmed code, then sync it.
      await sales.completeSale(
        lines: [CartLine(medicineId: med, mode: PriceMode.strip, count: 1)],
        cashierId: cashier.id,
        method: PaymentMethod.mpesa,
        mpesaCode: paid.receipt,
      );
      // And one sale with a code typed by hand that no prompt produced.
      await sales.completeSale(
        lines: [CartLine(medicineId: med, mode: PriceMode.strip, count: 1)],
        cashierId: cashier.id,
        method: PaymentMethod.mpesa,
        mpesaCode: 'HAND123456',
      );
      final r = await sync.syncNow();
      expect(r.message, isNull);
      expect(r.outcome, SyncOutcome.ok);

      final note = Platform.environment['EMUKTAN_LIVE_NOTE'];
      if (note != null) {
        File(note).writeAsStringSync('${paid.receipt}\n');
      }
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
