import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/dpapi.dart';
import 'package:emuktan_pos/core/key_store.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xff));

Future<int> _seedUser(AppDatabase db) => db.into(db.users).insert(
    UsersCompanion.insert(
        username: 'owner',
        displayName: 'Owner',
        role: Role.owner,
        secretHash: 'x',
        secretSalt: 'y'));

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('emuktan_test_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('SQLCipher is the SQLite in use', () async {
    final db = AppDatabase.encrypted(File(p.join(dir.path, 'a.db')), _key(1));
    final row = await db.customSelect('PRAGMA cipher_version').getSingle();
    expect(row.data.values.first.toString(), isNotEmpty);
    await db.close();
  });

  test('database file is not readable as plain SQLite', () async {
    final f = File(p.join(dir.path, 'b.db'));
    final db = AppDatabase.encrypted(f, _key(2));
    final uid = await _seedUser(db);
    await db.into(db.patients).insert(PatientsCompanion.insert(
        fullName: 'Jane Wanjiru Distinctivename', createdBy: uid));
    await db.close();

    final bytes = f.readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(15)), isNot('SQLite format 3'));
    expect(String.fromCharCodes(bytes).contains('Distinctivename'), isFalse);
  });

  test('right key reopens the data, wrong key is refused', () async {
    final f = File(p.join(dir.path, 'c.db'));
    var db = AppDatabase.encrypted(f, _key(3));
    final uid = await _seedUser(db);
    await db.into(db.patients).insert(
        PatientsCompanion.insert(fullName: 'Persisted', createdBy: uid));
    await db.close();

    db = AppDatabase.encrypted(f, _key(3));
    expect((await db.select(db.patients).get()).single.fullName, 'Persisted');
    await db.close();

    final wrong = AppDatabase.encrypted(f, _key(4));
    await expectLater(
        wrong.select(wrong.patients).get(), throwsA(isA<Object>()));
    await wrong.close().catchError((_) {});
  });

  test('foreign keys are enforced', () async {
    final db = AppDatabase.encrypted(File(p.join(dir.path, 'd.db')), _key(5));
    await expectLater(
        db.into(db.patients).insert(
            PatientsCompanion.insert(fullName: 'Orphan', createdBy: 999)),
        throwsA(isA<Object>()));
    await db.close();
  });

  test('stock on hand is the sum of movements, partial units work', () async {
    final db = AppDatabase.encrypted(File(p.join(dir.path, 'e.db')), _key(6));
    final uid = await _seedUser(db);
    final med = await db.into(db.medicines).insert(MedicinesCompanion.insert(
        name: 'Paracetamol 500mg',
        createdBy: uid,
        baseUnitName: const Value('tablet'),
        unitsPerStrip: const Value(10),
        unitsPerPack: const Value(100),
        pricePerUnitCents: const Value(500)));
    final batch = await db.into(db.batches).insert(BatchesCompanion.insert(
        medicineId: med, batchNumber: 'B1', createdBy: uid));
    Future<void> move(int q, MovementReason r) =>
        db.into(db.stockMovements).insert(StockMovementsCompanion.insert(
            batchId: batch, qtyDelta: q, reason: r, createdBy: uid));
    await move(100, MovementReason.receipt);
    await move(-3, MovementReason.sale); // three single tablets
    await move(-10, MovementReason.sale); // one strip
    expect(await db.stockOnHand(batch), 87);
    await db.close();
  });

  test('same batch number twice for one medicine is rejected', () async {
    final db = AppDatabase.encrypted(File(p.join(dir.path, 'f.db')), _key(7));
    final uid = await _seedUser(db);
    final med = await db.into(db.medicines)
        .insert(MedicinesCompanion.insert(name: 'X', createdBy: uid));
    await db.into(db.batches).insert(BatchesCompanion.insert(
        medicineId: med, batchNumber: 'B1', createdBy: uid));
    await expectLater(
        db.into(db.batches).insert(BatchesCompanion.insert(
            medicineId: med, batchNumber: 'B1', createdBy: uid)),
        throwsA(isA<Object>()));
    await db.close();
  });

  test('backupTo produces an ENCRYPTED snapshot that opens with the same key',
      () async {
    final live = File(p.join(dir.path, 'g.db'));
    final snap = p.join(dir.path, 'snapshot.db');
    final db = AppDatabase.encrypted(live, _key(8));
    final uid = await _seedUser(db);
    await db.into(db.patients).insert(PatientsCompanion.insert(
        fullName: 'Backupmarker Person', createdBy: uid));
    await db.backupTo(snap);
    await db.close();

    final bytes = File(snap).readAsBytesSync();
    expect(String.fromCharCodes(bytes.take(15)), isNot('SQLite format 3'),
        reason: 'VACUUM INTO must not write an unencrypted copy');
    expect(String.fromCharCodes(bytes).contains('Backupmarker'), isFalse);

    final restored = AppDatabase.encrypted(File(snap), _key(8));
    expect((await restored.select(restored.patients).get()).single.fullName,
        'Backupmarker Person');
    await restored.close();
  });

  test('recovery key round-trips and rejects bad input', () {
    final k = _key(9);
    final text = formatRecoveryKey(k);
    expect(text.split('-'), hasLength(8));
    expect(parseRecoveryKey(text), k);
    expect(parseRecoveryKey(text.toUpperCase().replaceAll('-', ' ')), k);
    expect(() => parseRecoveryKey('abc'), throwsFormatException);
  });

  test('DPAPI key store: create once, reload same key, file is not the raw key',
      () async {
    final store = DpapiKeyStore(File(p.join(dir.path, 'db.key')));
    final first = await store.loadOrCreate();
    expect(first.created, isTrue);
    expect(first.key, hasLength(32));
    final second = await store.loadOrCreate();
    expect(second.created, isFalse);
    expect(second.key, first.key);
    expect(File(p.join(dir.path, 'db.key')).readAsBytesSync(),
        isNot(first.key));
    expect(Dpapi.unprotect(Dpapi.protect(_key(1))), _key(1));
  });

  test('bootstrap: first run reports a recovery key, second run does not',
      () async {
    final a = await bootstrap(dataDir: dir);
    expect(a.newRecoveryKey, isNotNull);
    await a.db.close();
    final b = await bootstrap(dataDir: dir);
    expect(b.newRecoveryKey, isNull);
    await b.db.close();
  });
}
