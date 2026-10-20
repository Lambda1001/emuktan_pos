import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:emuktan_pos/config/app_config.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/patient_service.dart';
import 'package:emuktan_pos/data/sales_admin_service.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/sync_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/cart.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the server and records what it was sent.
class FakeServer implements SyncTransport {
  final posts = <Map<String, dynamic>>[];
  int status = 200;
  Map<String, dynamic>? reply;
  Object? throwOnSend;

  @override
  Future<SyncReply> get(Uri url, String key) async {
    if (throwOnSend != null) throw throwOnSend!;
    return SyncReply(key == 'good-key-good-key-1' ? 200 : 401, {
      'ok': true,
      'clinic': 'Emuktan',
    });
  }

  @override
  Future<SyncReply> postFile(Uri url, String key, File file) async =>
      SyncReply(200, {'stored': 'x.db', 'bytes': file.lengthSync()});

  @override
  Future<SyncReply> post(Uri url, String key, Object body) async {
    if (throwOnSend != null) throw throwOnSend!;
    // Round-trip through JSON, as the wire would.
    posts.add(jsonDecode(jsonEncode(body)) as Map<String, dynamic>);
    return SyncReply(status, reply ?? {'accepted': 0});
  }

  List<Map<String, dynamic>> get rows => [
    for (final p in posts) ...(p['rows'] as List).cast<Map<String, dynamic>>(),
  ];
}

void main() {
  late AppDatabase db;
  late AuthService auth;
  late StockService stock;
  late SalesService sales;
  late SalesAdminService admin;
  late PatientService patients;
  late FakeServer server;
  late SyncService sync;
  late User owner, cashier;
  late int med;
  var clock = DateTime(2026, 10, 10, 14, 32);
  const key = 'good-key-good-key-1';
  const url = 'https://dash.example.co.ke';

  setUp(() async {
    clock = DateTime(2026, 10, 10, 14, 32);
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    stock = StockService(db, clock: () => clock);
    sales = SalesService(db, stock, clock: () => clock);
    admin = SalesAdminService(db, clock: () => clock);
    patients = PatientService(db);
    server = FakeServer();
    sync = SyncService(db, transport: server, clock: () => clock);
    owner = await auth.createUser(
      displayName: 'Wanjiru Kamau',
      role: Role.owner,
      pin: '4821',
    );
    cashier = await auth.createUser(
      displayName: 'Jane Doe',
      role: Role.cashier,
      pin: '1357',
    );
    med = await stock.createMedicine(
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
  });
  tearDown(() => db.close());

  Future<void> receive() => stock.receiveStock(
    medicineId: med,
    batchNumber: 'B1',
    expiry: DateTime(2027, 12, 31),
    qtyBaseUnits: 500,
    costPerUnitCents: 500,
    userId: owner.id,
  );

  Future<SaleReceipt> sell({int? patientId}) => sales.completeSale(
    lines: [CartLine(medicineId: med, mode: PriceMode.strip, count: 2)],
    cashierId: cashier.id,
    method: PaymentMethod.cash,
    cashTenderedCents: 20000,
    patientId: patientId,
  );

  Future<List<SyncOutboxData>> outbox() => (db.select(
    db.syncOutbox,
  )..orderBy([(r) => OrderingTerm.asc(r.id)])).get();

  Future<void> configure() => sync.configure(url: url, key: key);

  group('queueing changes', () {
    test('a sale queues its rows, parents before children', () async {
      await receive();
      await sell();
      final entities = (await outbox()).map((r) => r.entity).toList();
      expect(entities.first, 'staff');
      for (final e in [
        'medicine',
        'batch',
        'stock_movement',
        'sale',
        'sale_item',
        'payment',
      ]) {
        expect(entities, contains(e));
      }
      // The sale is queued before its items and payment.
      expect(entities.indexOf('sale'), lessThan(entities.indexOf('sale_item')));
      expect(entities.indexOf('sale'), lessThan(entities.indexOf('payment')));
      expect(entities.indexOf('medicine'), lessThan(entities.indexOf('batch')));
    });

    test('payloads use the wire format: names, UTC times, dates', () async {
      await receive();
      final r = await sell();
      final all = await outbox();
      final sale = all.firstWhere((o) => o.entity == 'sale');
      final data = jsonDecode(sale.payloadJson) as Map<String, dynamic>;
      expect(sale.entityId, isPositive);
      expect(data['receipt_no'], r.receiptNo);
      expect(data['cashier_local_id'], cashier.id);
      expect(data['status'], 'completed');
      expect(data['total_cents'], 18000);
      expect(data['voided_at'], isNull);
      expect(
        data['created_at'],
        matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$')),
      );

      final batch = all.firstWhere((o) => o.entity == 'batch');
      final b = jsonDecode(batch.payloadJson) as Map<String, dynamic>;
      expect(b['expiry_date'], '2027-12-31');
      expect(b['cost_per_unit_cents'], 500);
      expect(b['medicine_local_id'], med);
    });

    test('a void and a return are queued as changes', () async {
      await receive();
      final r = await sell();
      final saleId = (await db.select(db.sales).get()).single.id;
      await db.delete(db.syncOutbox).go();
      await admin.voidSale(
        saleId: saleId,
        reason: 'Wrong item',
        approverId: owner.id,
        actingUserId: owner.id,
      );
      final rows = await outbox();
      final sale = rows.lastWhere((o) => o.entity == 'sale');
      final data = jsonDecode(sale.payloadJson) as Map<String, dynamic>;
      expect(data['status'], 'voided');
      expect(data['void_reason'], 'Wrong item');
      expect(data['voided_at'], isNotNull);
      expect(r.receiptNo, data['receipt_no']);
      // Stock came back: the reversing movement is queued too.
      expect(rows.where((o) => o.entity == 'stock_movement'), isNotEmpty);
    });

    test('a PIN change is not queued; a name change is', () async {
      await db.delete(db.syncOutbox).go();
      await (db.update(db.users)..where((u) => u.id.equals(owner.id))).write(
        const UsersCompanion(secretHash: Value('x')),
      );
      expect(await outbox(), isEmpty);
      await (db.update(db.users)..where((u) => u.id.equals(owner.id))).write(
        const UsersCompanion(displayName: Value('Wanjiru K.')),
      );
      final rows = await outbox();
      expect(rows.single.entity, 'staff');
    });

    test(
      'no patient data and no private fields ever reach the queue',
      () async {
        await receive();
        final p = await patients.register(
          const PatientInput(
            fullName: 'Secret Patient',
            phone: '0712345678',
            allergies: 'penicillin',
          ),
          userId: owner.id,
        );
        await patients.recordVisit(
          p.id,
          userId: owner.id,
          notes: 'confidential consultation',
        );
        await sell(patientId: p.id);

        final all = await outbox();
        const banned = [
          'Secret Patient',
          '0712345678',
          'penicillin',
          'confidential',
          'patient_id',
          'visit_id',
          'secret_hash',
          'secret_salt',
          'username',
          'supplier_note',
          '"note"',
        ];
        for (final o in all) {
          expect({
            'staff',
            'medicine',
            'batch',
            'sale',
            'sale_item',
            'payment',
            'stock_movement',
            'sale_return',
          }, contains(o.entity));
          for (final b in banned) {
            expect(o.payloadJson, isNot(contains(b)), reason: o.entity);
          }
        }
      },
    );
  });

  group('configuring', () {
    test('needs https, except on this PC', () {
      expect(
        () => SyncService.parseBaseUrl('http://dash.example.co.ke'),
        throwsA(isA<SyncException>()),
      );
      expect(
        () => SyncService.parseBaseUrl('not a url'),
        throwsA(isA<SyncException>()),
      );
      expect(
        SyncService.parseBaseUrl('http://localhost:8000/').toString(),
        'http://localhost:8000',
      );
      expect(
        SyncService.parseBaseUrl('https://dash.example.co.ke/').host,
        'dash.example.co.ke',
      );
    });

    test('rejects a short key', () async {
      expect(
        () => sync.configure(url: url, key: 'abc'),
        throwsA(isA<SyncException>()),
      );
      expect(await sync.config(), isNull);
    });

    test('the first time, what already exists is queued, once', () async {
      await receive();
      await sell();
      await db.delete(db.syncOutbox).go(); // pretend they were never queued
      await configure();
      final first = (await outbox()).length;
      expect(first, greaterThan(5));
      final entities = (await outbox()).map((r) => r.entity).toList();
      expect(entities.first, 'staff');
      expect(entities.indexOf('sale'), lessThan(entities.indexOf('sale_item')));

      await configure(); // saving again must not queue everything twice
      expect((await outbox()).length, first);
    });

    test(
      'testConnection reports the clinic, a bad key, and no network',
      () async {
        expect(await sync.testConnection(url: url, key: key), 'Emuktan');
        expect(
          () => sync.testConnection(url: url, key: 'wrong-wrong-wrong-1'),
          throwsA(isA<SyncException>()),
        );
        server.throwOnSend = const SocketException('down');
        expect(
          () => sync.testConnection(url: url, key: key),
          throwsA(isA<SyncException>()),
        );
      },
    );
  });

  group('pushing', () {
    test('does nothing until configured', () async {
      final r = await sync.syncNow();
      expect(r.outcome, SyncOutcome.notConfigured);
      expect(server.posts, isEmpty);
    });

    test('sends the queue in order and marks it sent', () async {
      await configure();
      await receive();
      await sell();
      final queued = await outbox();

      final r = await sync.syncNow();
      expect(r.outcome, SyncOutcome.ok);
      expect(r.sent, queued.length);
      expect(server.posts.single['app_version'], SyncConfig.appVersion);
      expect(server.rows.map((x) => x['entity']), queued.map((x) => x.entity));
      expect(
        server.rows.first.keys,
        containsAll(['entity', 'local_id', 'data']),
      );
      expect((await outbox()).every((o) => o.sentAt != null), isTrue);

      final s = await sync.status();
      expect(s.pending, 0);
      expect(s.lastOkAt, clock);
      expect(s.lastError, isNull);
    });

    test('with nothing queued it still checks in', () async {
      await configure();
      await sync.syncNow();
      server.posts.clear();
      final r = await sync.syncNow();
      expect(r.outcome, SyncOutcome.ok);
      expect(server.posts.single['rows'], isEmpty);
    });

    test('sends only what is new next time', () async {
      await configure();
      await receive();
      await sync.syncNow();
      server.posts.clear();
      await sell();
      await sync.syncNow();
      expect(server.rows.map((x) => x['entity']), isNot(contains('medicine')));
      expect(server.rows.map((x) => x['entity']), contains('sale'));
    });

    test('offline: nothing is lost, nothing is marked sent', () async {
      await configure();
      await receive();
      final before = (await sync.status()).pending;
      server.throwOnSend = const SocketException('down');
      final r = await sync.syncNow();
      expect(r.outcome, SyncOutcome.offline);
      final s = await sync.status();
      expect(s.pending, before);
      expect(s.lastError, isNotNull);
      expect(s.lastOkAt, isNull);

      server.throwOnSend = null;
      expect((await sync.syncNow()).outcome, SyncOutcome.ok);
      expect((await sync.status()).pending, 0);
    });

    test('a timeout is treated as offline', () async {
      await configure();
      server.throwOnSend = TimeoutException('slow');
      expect((await sync.syncNow()).outcome, SyncOutcome.offline);
    });

    test('a refused batch stays queued and says why', () async {
      await configure();
      await receive();
      final before = (await sync.status()).pending;
      server.status = 422;
      server.reply = {'error': 'parent missing', 'index': 3};
      final r = await sync.syncNow();
      expect(r.outcome, SyncOutcome.rejected);
      expect(r.message, contains('parent missing'));
      expect((await sync.status()).pending, before);
    });

    test('a wrong key is reported plainly', () async {
      await configure();
      server.status = 401;
      final r = await sync.syncNow();
      expect(r.outcome, SyncOutcome.rejected);
      expect(r.message, contains('key'));
    });

    test('big queues go in batches of at most the limit', () async {
      await configure();
      final n = SyncConfig.batchSize * 2 + 10;
      await db.batch((b) {
        b.insertAll(db.syncOutbox, [
          for (var i = 1; i <= n; i++)
            SyncOutboxCompanion.insert(
              entity: 'medicine',
              entityId: i,
              payloadJson: '{"name":"m$i"}',
            ),
        ]);
      });
      await db.delete(db.syncOutbox).go(); // clear rows queued by setUp
      await db.batch((b) {
        b.insertAll(db.syncOutbox, [
          for (var i = 1; i <= n; i++)
            SyncOutboxCompanion.insert(
              entity: 'medicine',
              entityId: i,
              payloadJson: '{"name":"m$i"}',
            ),
        ]);
      });
      final r = await sync.syncNow();
      expect(r.outcome, SyncOutcome.ok);
      expect(r.sent, n);
      expect(server.posts.map((p) => (p['rows'] as List).length), [
        SyncConfig.batchSize,
        SyncConfig.batchSize,
        10,
      ]);
      // In order, nothing repeated.
      expect(server.rows.map((x) => x['local_id']), [
        for (var i = 1; i <= n; i++) i,
      ]);
    });

    test('sent rows are removed after a month', () async {
      await configure();
      await receive();
      await sync.syncNow();
      expect((await outbox()), isNotEmpty);
      clock = clock.add(SyncConfig.keepSent + const Duration(days: 1));
      await sync.syncNow();
      expect(await outbox(), isEmpty);
    });

    test('stale means nothing got through for a day', () async {
      await configure();
      expect((await sync.status()).isStale(clock), isTrue); // never synced
      await sync.syncNow();
      final s = await sync.status();
      expect(s.isStale(clock.add(const Duration(hours: 23))), isFalse);
      expect(s.isStale(clock.add(const Duration(hours: 25))), isTrue);
    });
  });
}
