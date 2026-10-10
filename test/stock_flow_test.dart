import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the real app: sign in, open Stock, and use the dialogs.
void main() {
  late AppDatabase db;
  late AuthService auth;
  late StockService stock;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    stock = StockService(db);
    await auth.createUser(
      displayName: 'Wanjiru Kamau',
      role: Role.owner,
      pin: '4821',
    );
    await auth.createUser(
      displayName: 'Jane Doe',
      role: Role.cashier,
      pin: '1357',
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
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('owner adds a medicine, receives stock, and sees it in stock', (
    tester,
  ) async {
    await signInAs(tester, 'Wanjiru Kamau', '4821');
    expect(find.text('No medicines yet'), findsOneWidget);

    await tester.tap(find.text('Add medicine'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Medicine name'), 'Paracetamol 500mg');
    await tester.enterText(field('Units per strip'), '10');
    await tester.enterText(field('Price per strip'), '90');
    await tester.enterText(field('Price per single'), '10');
    await tester.enterText(field('Low-stock level'), '200');
    await tester.tap(find.widgetWithText(FilledButton, 'Add medicine').last);
    await tester.pumpAndSettle();

    expect(find.text('Paracetamol 500mg'), findsOneWidget);
    expect(find.text('Out of stock'), findsOneWidget);

    // Receive 5 strips at KES 60 each, from the row.
    await tester.tap(find.text('Receive').first);
    await tester.pumpAndSettle();
    await tester.enterText(field('Batch number'), 'B-100');
    await tester.enterText(field('Expiry (month/year)'), '12/2099');
    await tester.enterText(field('How many strips'), '5');
    await tester.enterText(field('Cost per strip'), '60');
    await tester.pumpAndSettle();
    expect(
      find.textContaining('= 50 tablets, costing KES 6 each'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Receive stock').last);
    await tester.pumpAndSettle();

    expect(find.text('50 tablets'), findsOneWidget);
    expect(find.text('Dec 2099'), findsOneWidget);
    // 50 <= level of 200. "Low stock" is also a filter label, so look in the list.
    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.text('Low stock'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a bad barcode clash shows a plain message and nothing is added',
    (tester) async {
      await stock.createMedicine(
        const MedicineInput(
          name: 'Amoxil',
          barcode: '777',
          pricePerUnitCents: 500,
        ),
        userId: 1,
      );
      await signInAs(tester, 'Wanjiru Kamau', '4821');
      await tester.tap(find.text('Add medicine'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Medicine name'), 'Other');
      await tester.enterText(field('Barcode (optional)'), '777');
      await tester.enterText(field('Price per single'), '5');
      await tester.tap(find.widgetWithText(FilledButton, 'Add medicine').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Another medicine already uses this barcode.'),
        findsOneWidget,
      );
      expect((await tester.runAsync(stock.listStock))!.length, 1);
    },
  );

  testWidgets('a cashier can receive but cannot add or edit medicines', (
    tester,
  ) async {
    await stock.createMedicine(
      const MedicineInput(name: 'Amoxil', pricePerUnitCents: 500),
      userId: 1,
    );
    await signInAs(tester, 'Jane Doe', '1357');
    expect(find.text('Amoxil'), findsOneWidget);
    expect(find.text('Receive stock'), findsOneWidget);
    expect(find.text('Add medicine'), findsNothing);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Receive'), findsOneWidget);
  });

  testWidgets('owner can write off an expired batch from the batches sheet', (
    tester,
  ) async {
    final med = await stock.createMedicine(
      const MedicineInput(name: 'Amoxil', pricePerUnitCents: 500),
      userId: 1,
    );
    // Received while valid, now past its date (clock in the service is real,
    // so seed the batch directly with a past expiry).
    final batch = await db
        .into(db.batches)
        .insert(
          BatchesCompanion.insert(
            medicineId: med,
            batchNumber: 'OLD',
            expiryDate: Value(DateTime(2020, 1, 31)),
            createdBy: 1,
          ),
        );
    await db
        .into(db.stockMovements)
        .insert(
          StockMovementsCompanion.insert(
            batchId: batch,
            qtyDelta: 40,
            reason: MovementReason.receipt,
            createdBy: 1,
          ),
        );

    await signInAs(tester, 'Wanjiru Kamau', '4821');
    expect(find.text('Expired'), findsWidgets);

    await tester.tap(find.text('Batches'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adjust'));
    await tester.pumpAndSettle();
    await tester.enterText(field('How many tablets'), '40');
    await tester.enterText(field('Reason'), 'expired, disposed');
    await tester.tap(find.widgetWithText(FilledButton, 'Write off'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(await tester.runAsync(() => db.stockOnHand(batch)), 0);
    expect(find.text('Out of stock'), findsOneWidget);
  });
}
