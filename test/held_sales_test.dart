import 'dart:io';

import 'package:drift/native.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/held_sales_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/cart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw;

void main() {
  late AppDatabase db;
  late HeldSalesService held;
  late User owner, cashier;
  var now = DateTime(2026, 10, 10, 14, 30);

  const strips = CartLine(medicineId: 1, mode: PriceMode.strip, count: 3);
  const singles = CartLine(medicineId: 2, mode: PriceMode.unit, count: 5);

  setUp(() async {
    now = DateTime(2026, 10, 10, 14, 30);
    db = AppDatabase(NativeDatabase.memory());
    held = HeldSalesService(db, clock: () => now);
    final auth = AuthService(db, hasher: const PinHasher(iterations: 10));
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
  });
  tearDown(() => db.close());

  test('a parked sale comes back exactly as it was left', () async {
    final id = await held.park(
      lines: [strips, singles],
      userId: cashier.id,
      label: '  Mrs Achieng  ',
      discountCents: 1000,
      discountApprovedBy: owner.id,
    );

    final back = await held.take(id);
    expect(back.label, 'Mrs Achieng');
    expect(back.lines.length, 2);
    expect(back.lines[0].medicineId, 1);
    expect(back.lines[0].mode, PriceMode.strip);
    expect(back.lines[0].count, 3);
    expect(back.lines[1].mode, PriceMode.unit);
    expect(back.discountCents, 1000);
    expect(back.approverId, owner.id);
    expect(back.approverName, 'Wanjiru Kamau');
    expect(back.parkedByName, 'Jane Doe');
    expect(back.createdAt, now);
  });

  test('taking it removes it, so it can only be picked up once', () async {
    final id = await held.park(lines: [strips], userId: cashier.id);
    await held.take(id);
    expect(await held.count(), 0);
    await expectLater(held.take(id), throwsA(isA<HeldSaleException>()));
  });

  test('the list is oldest first and shows who parked each', () async {
    await held.park(lines: [strips], userId: cashier.id, label: 'First');
    now = now.add(const Duration(minutes: 7));
    await held.park(lines: [singles], userId: owner.id, label: 'Second');
    final list = await held.list();
    expect(list.map((h) => h.label), ['First', 'Second']);
    expect(list.map((h) => h.parkedByName), ['Jane Doe', 'Wanjiru Kamau']);
  });

  test('a blank name is stored as no name', () async {
    final id = await held.park(lines: [strips], userId: 1, label: '   ');
    expect((await held.take(id)).label, isNull);
  });

  test('discard removes a parked sale', () async {
    final id = await held.park(lines: [strips], userId: 1);
    await held.discard(id);
    expect(await held.list(), isEmpty);
  });

  test('refuses an empty sale, an unapproved discount, a long name', () async {
    await expectLater(
      held.park(lines: const [], userId: 1),
      throwsA(isA<HeldSaleException>()),
    );
    await expectLater(
      held.park(lines: [strips], userId: 1, discountCents: 500),
      throwsA(isA<HeldSaleException>()),
    );
    await expectLater(
      held.park(lines: [strips], userId: 1, label: 'x' * 41),
      throwsA(isA<HeldSaleException>()),
    );
    expect(await held.count(), 0);
  });

  test('there is a limit, with a plain message', () async {
    for (var i = 0; i < HeldSalesService.maxParked; i++) {
      await held.park(lines: [strips], userId: 1);
    }
    await expectLater(
      held.park(lines: [strips], userId: 1),
      throwsA(
        isA<HeldSaleException>().having(
          (e) => e.message,
          'message',
          contains('already 20 parked sales'),
        ),
      ),
    );
  });

  test('a damaged entry is skipped instead of losing the whole sale', () async {
    final id = await db
        .into(db.heldSales)
        .insert(
          HeldSalesCompanion.insert(
            linesJson:
                '[{"m":1,"mode":"strip","n":2},{"m":"bad"},{"m":2,"mode":"nonsense","n":1},{"m":3,"mode":"unit","n":0}]',
            parkedBy: 1,
          ),
        );
    final back = await held.take(id);
    expect(back.lines.length, 1);
    expect(back.lines.single.count, 2);
  });

  test('completely unreadable lines give an empty sale, not a crash', () async {
    final id = await db
        .into(db.heldSales)
        .insert(HeldSalesCompanion.insert(linesJson: 'not json', parkedBy: 1));
    expect((await held.take(id)).lines, isEmpty);
  });

  test('a version 2 database upgrades and keeps its data', () async {
    final dir = Directory.systemTemp.createTempSync('emuktan_mig3_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File(p.join(dir.path, 'v2.db'));

    var d = AppDatabase(NativeDatabase(file));
    await d
        .into(d.users)
        .insert(
          UsersCompanion.insert(
            username: 'owner',
            displayName: 'Owner',
            role: Role.owner,
            secretHash: 'h',
            secretSalt: 's',
          ),
        );
    await d.close();
    final conn = raw.sqlite3.open(file.path);
    conn.execute('DROP TABLE held_sales');
    conn.execute('PRAGMA user_version = 2');
    conn.close();

    d = AppDatabase(NativeDatabase(file));
    expect(await d.select(d.heldSales).get(), isEmpty); // the table is back
    expect((await d.select(d.users).get()).single.username, 'owner');
    final v = await d.customSelect('PRAGMA user_version').getSingle();
    expect(v.data.values.first, AppDatabase.currentSchemaVersion);
    await d.close();
  });
}
