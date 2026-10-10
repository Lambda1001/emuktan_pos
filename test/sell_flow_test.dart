import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the real app at the counter: sign in as a cashier and sell.
void main() {
  late AppDatabase db;
  late AuthService auth;
  late StockService stock;
  late SalesService sales;
  late int med;
  late User cashier, clinician;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    stock = StockService(db);
    sales = SalesService(db, stock);
    final owner = await auth.createUser(
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
        barcode: '6001',
        unitsPerStrip: 10,
        pricePerStripCents: 9000,
        pricePerUnitCents: 1000,
      ),
      userId: owner.id,
    );
    await stock.receiveStock(
      medicineId: med,
      batchNumber: 'B1',
      expiry: DateTime(2099, 12, 31),
      qtyBaseUnits: 100,
      costPerUnitCents: 500,
      userId: owner.id,
    );
  });
  tearDown(() => db.close());

  Future<void> signInAs(WidgetTester tester, String name, String pin) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          stockServiceProvider.overrideWithValue(stock),
          salesServiceProvider.overrideWithValue(sales),
        ],
        child: EmuktanApp(
          open: () async => AppContext(
            db: db,
            dataDir: Directory.systemTemp,
            newRecoveryKey: null,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), pin);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);
  Future<void> addFirstResult(WidgetTester tester) async {
    await tester.tap(find.text('Paracetamol 500mg').first);
    await tester.pumpAndSettle();
  }

  testWidgets('cashier sells for cash and stock goes down', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    expect(find.text('Nothing in the sale yet'), findsOneWidget);
    expect(find.text('Add a medicine to start a sale.'), findsOneWidget);

    await addFirstResult(tester);
    await tester.tap(find.byTooltip('One more'));
    await tester.pump();
    await tester.tap(find.byTooltip('One more'));
    await tester.pumpAndSettle();
    expect(find.text('3 tablets'), findsOneWidget);
    expect(find.text('Charge KES 30'), findsOneWidget);

    await tester.enterText(field('Cash received'), '50');
    await tester.pumpAndSettle();
    expect(find.text('KES 20.00'), findsOneWidget); // change due

    await tester.tap(find.text('Charge KES 30'));
    await tester.pumpAndSettle();
    expect(find.text('Sale complete'), findsOneWidget);
    expect(
      find.textContaining('Give the customer KES 20.00 change'),
      findsOneWidget,
    );
    expect(find.textContaining('R'), findsWidgets);

    await tester.tap(find.text('New sale'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing in the sale yet'), findsOneWidget);
    expect(await tester.runAsync(() => db.stockOnHand(1)), 97);
    final sale = (await tester.runAsync(
      () => db.select(db.sales).getSingle(),
    ))!;
    expect(sale.cashierId, cashier.id);
    expect(sale.totalCents, 3000);
  });

  testWidgets('a scanned barcode plus Enter adds the medicine', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await tester.enterText(
      field('Search name or scan barcode   (Ctrl+K)'),
      '6001',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Charge KES 10'), findsOneWidget);
  });

  testWidgets('selling by the strip shows what leaves stock', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Strip').first);
    await tester.pumpAndSettle();
    expect(find.text('1 strip = 10 tablets'), findsOneWidget);
    expect(find.text('Charge KES 90'), findsOneWidget);
  });

  testWidgets('M-Pesa needs the code, then completes', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('M-Pesa'));
    await tester.pumpAndSettle();
    expect(
      find.text('Enter the M-Pesa code from the message.'),
      findsOneWidget,
    );

    await tester.enterText(field('M-Pesa transaction code'), 'qgh7k2lmnp');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charge KES 10'));
    await tester.pumpAndSettle();
    expect(find.textContaining('code QGH7K2LMNP'), findsOneWidget);
  });

  testWidgets('cashier discount needs the owner or clinician PIN', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Strip').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add discount'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Discount amount'), '10');
    await tester.enterText(field('Approver’s PIN'), '1357'); // cashier's own
    await tester.tap(find.text('Apply discount'));
    await tester.pumpAndSettle();
    expect(find.textContaining('That PIN is not right'), findsOneWidget);
    expect(find.text('Charge KES 90'), findsOneWidget);

    await tester.enterText(field('Approver’s PIN'), '8642'); // clinician
    await tester.tap(find.text('Apply discount'));
    await tester.pumpAndSettle();
    expect(find.textContaining('approved by Peter Njoroge'), findsOneWidget);
    expect(find.text('Charge KES 80'), findsOneWidget);

    await tester.tap(find.text('Charge KES 80'));
    await tester.pumpAndSettle();
    final sale = (await tester.runAsync(
      () => db.select(db.sales).getSingle(),
    ))!;
    expect(sale.discountCents, 1000);
    expect(sale.discountAuthorisedBy, clinician.id);
    expect(sale.totalCents, 8000);
  });

  testWidgets('selling more than is in stock is blocked with a plain reason', (
    tester,
  ) async {
    await db.customStatement('DELETE FROM stock_movements');
    await db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            batchId: 1,
            qtyDelta: 2,
            reason: MovementReason.receipt,
            createdBy: 1,
          ),
        );
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.byTooltip('One more'));
    await tester.pump();
    await tester.tap(find.byTooltip('One more'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Only 2 tablets in stock'), findsOneWidget);
    expect(find.text('Fix the lines marked in red first.'), findsOneWidget);
    final charge = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Charge KES 30'),
    );
    expect(charge.onPressed, isNull);
  });

  testWidgets(
    'expired stock warns, and the sale only goes ahead if confirmed',
    (tester) async {
      await db.customStatement('DELETE FROM stock_movements');
      await (db.update(
        db.batches,
      )).write(BatchesCompanion(expiryDate: Value(DateTime(2020, 1, 31))));
      await db
          .into(db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              batchId: 1,
              qtyDelta: 50,
              reason: MovementReason.receipt,
              createdBy: 1,
            ),
          );
      await signInAs(tester, 'Jane Doe', '1357');
      await addFirstResult(tester);
      expect(find.text('This sale includes expired stock.'), findsOneWidget);
      expect(find.textContaining('Expired. Do not sell.'), findsOneWidget);

      await tester.tap(find.text('Charge KES 10'));
      await tester.pumpAndSettle();
      expect(find.text('This sale includes expired stock'), findsOneWidget);
      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => db.select(db.sales).get()), isEmpty);

      await tester.tap(find.text('Charge KES 10'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sell anyway'));
      await tester.pumpAndSettle();
      expect(find.text('Sale complete'), findsOneWidget);
      expect(
        await tester.runAsync(() => db.select(db.sales).get()),
        hasLength(1),
      );
    },
  );

  testWidgets('the cart survives a visit to Stock', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    expect(find.text('Charge KES 10'), findsOneWidget);
  });
}
