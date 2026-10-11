import 'dart:io';

import 'package:drift/native.dart';
import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/sales_admin_service.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/cart.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the real app on the Sales page.
void main() {
  late AppDatabase db;
  late AuthService auth;
  late StockService stock;
  late SalesService sales;
  late SalesAdminService admin;
  late int med, batch;
  late String receiptNo;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    stock = StockService(db);
    sales = SalesService(db, stock);
    admin = SalesAdminService(db);
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
    await auth.createUser(
      displayName: 'Peter Njoroge',
      role: Role.clinician,
      pin: '8642',
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
    final r = await sales.completeSale(
      lines: [CartLine(medicineId: med, mode: PriceMode.strip, count: 3)],
      cashierId: cashier.id,
      method: PaymentMethod.cash,
    );
    receiptNo = r.receiptNo;
  });
  tearDown(() => db.close());

  Future<void> openSalesAs(WidgetTester tester, String name, String pin) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          stockServiceProvider.overrideWithValue(stock),
          salesServiceProvider.overrideWithValue(sales),
          salesAdminServiceProvider.overrideWithValue(admin),
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
    await tester.tap(find.text('Sales').first);
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('the sale appears in today’s list and opens', (tester) async {
    await openSalesAs(tester, 'Jane Doe', '1357');
    expect(find.text(receiptNo), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.textContaining('1 sale,'), findsOneWidget);

    await tester.tap(find.text(receiptNo));
    await tester.pumpAndSettle();
    expect(find.text('Receipt $receiptNo'), findsOneWidget);
    expect(find.textContaining('30 tablets'), findsOneWidget);
    expect(find.textContaining('batch B1'), findsOneWidget);
  });

  testWidgets('search finds a sale by the end of its number', (tester) async {
    await openSalesAs(tester, 'Jane Doe', '1357');
    await tester.enterText(field('Find by receipt number'), '0001');
    await tester.pumpAndSettle();
    expect(find.text(receiptNo), findsOneWidget);
    await tester.enterText(field('Find by receipt number'), '9999');
    await tester.pumpAndSettle();
    expect(find.text('No receipt matches'), findsOneWidget);
  });

  testWidgets('a cashier voids a sale with a clinician’s PIN', (tester) async {
    await openSalesAs(tester, 'Jane Doe', '1357');
    await tester.tap(find.text(receiptNo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Void sale'));
    await tester.pumpAndSettle();

    await tester.enterText(field('Reason'), 'Rung up twice');
    await tester.enterText(field('Approver’s PIN'), '1357'); // own PIN
    await tester.tap(find.widgetWithText(FilledButton, 'Void sale'));
    await tester.pumpAndSettle();
    expect(find.textContaining('That PIN is not right'), findsOneWidget);
    expect(await tester.runAsync(() => db.stockOnHand(batch)), 70);

    await tester.enterText(field('Approver’s PIN'), '8642');
    await tester.tap(find.widgetWithText(FilledButton, 'Void sale'));
    await tester.pumpAndSettle();

    expect(find.textContaining('voided.'), findsOneWidget); // toast
    expect(find.textContaining('approved by Peter Njoroge'), findsOneWidget);
    expect(await tester.runAsync(() => db.stockOnHand(batch)), 100);
    // Void button is now off.
    final voidButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Void sale'),
    );
    expect(voidButton.onPressed, isNull);
  });

  testWidgets('owner returns a strip: refund shown, stock back, void closed', (
    tester,
  ) async {
    await openSalesAs(tester, 'Wanjiru Kamau', '4821');
    await tester.tap(find.text(receiptNo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Return items'));
    await tester.pumpAndSettle();

    await tester.enterText(field('tablet'), '10');
    await tester.enterText(field('Reason'), 'Wrong medicine');
    await tester.pumpAndSettle();
    expect(find.text('Refund KES 90.00'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Refund KES 90.00'));
    await tester.pumpAndSettle();

    expect(find.text('Items returned.'), findsOneWidget);
    expect(find.textContaining('10 tablets returned'), findsOneWidget);
    expect(
      find.textContaining('A sale with returns can no longer'),
      findsOneWidget,
    );
    expect(await tester.runAsync(() => db.stockOnHand(batch)), 80);
    final voidButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Void sale'),
    );
    expect(voidButton.onPressed, isNull);

    // And the list shows the refund after closing.
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Refunded KES 90'), findsOneWidget);
  });

  testWidgets('asking to return more than was sold shows a plain limit', (
    tester,
  ) async {
    await openSalesAs(tester, 'Wanjiru Kamau', '4821');
    await tester.tap(find.text(receiptNo));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Return items'));
    await tester.pumpAndSettle();
    await tester.enterText(field('tablet'), '31');
    await tester.pumpAndSettle();
    expect(find.text('At most 30'), findsOneWidget);
    final refund = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Refund'),
    );
    expect(refund.onPressed, isNull);
  });
}
