import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/patient_service.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/features/sell/pay_dialog.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // ---- the payment panel -------------------------------------------------

  Finder inPanel(Finder f) =>
      find.descendant(of: find.byType(PayDialog), matching: f);

  /// Taps keys on the on-screen number pad, for example '50' or '12.5'.
  Future<void> tapPad(WidgetTester tester, String keys) async {
    for (final k in keys.split('')) {
      await tester.tap(inPanel(find.widgetWithText(FilledButton, k)).first);
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  String cashShown(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('cash-received'))).data!;

  Future<void> openPay(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.byType(PayDialog), findsOneWidget);
  }

  testWidgets('the layout is products on the left and the sale on the right', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    final tile = tester.getTopLeft(find.text('Paracetamol 500mg').first);
    final sale = tester.getTopLeft(find.text('Sale').last);
    expect(tile.dx, lessThan(sale.dx));
    expect(find.text('Nothing in the sale yet'), findsOneWidget);
    expect(find.text('Add a medicine to start a sale.'), findsOneWidget);
  });

  testWidgets('cashier sells for cash with the number pad', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.byTooltip('One more'));
    await tester.pump();
    await tester.tap(find.byTooltip('One more'));
    await tester.pumpAndSettle();
    expect(find.text('3 tablets'), findsOneWidget);
    expect(find.text('Pay KES 30'), findsOneWidget);

    await openPay(tester, 'Pay KES 30');
    expect(inPanel(find.text('KES 30.00')), findsOneWidget); // total to pay
    final complete = find.widgetWithText(FilledButton, 'Complete sale');
    expect(tester.widget<FilledButton>(complete).onPressed, isNull);

    await tapPad(tester, '20');
    expect(cashShown(tester), 'KES 20');
    expect(find.text('KES 10.00'), findsOneWidget); // still to pay
    expect(tester.widget<FilledButton>(complete).onPressed, isNull);

    await tapPad(tester, '0'); // 200
    expect(cashShown(tester), 'KES 200');
    expect(find.text('KES 170.00'), findsOneWidget); // change due
    await tester.tap(complete);
    await tester.pumpAndSettle();

    expect(find.text('Sale complete'), findsOneWidget);
    expect(
      find.textContaining('Give the customer KES 170.00 change'),
      findsOneWidget,
    );
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

  testWidgets('quick notes, Exact, Delete and Clear change the amount', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await openPay(tester, 'Pay KES 10');

    await tester.tap(inPanel(find.text('KES 500')));
    await tester.pumpAndSettle();
    expect(cashShown(tester), 'KES 500');
    expect(find.text('KES 490.00'), findsOneWidget);

    await tester.tap(inPanel(find.text('Exact')));
    await tester.pumpAndSettle();
    expect(cashShown(tester), 'KES 10');
    expect(find.text('KES 0.00'), findsOneWidget);

    await tester.tap(inPanel(find.byTooltip('Delete the last digit')));
    await tester.pumpAndSettle();
    expect(cashShown(tester), 'KES 1');

    await tester.tap(inPanel(find.text('Clear')));
    await tester.pumpAndSettle();
    expect(cashShown(tester), 'KES 0');
  });

  testWidgets('the pad takes decimals, but only two places', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await openPay(tester, 'Pay KES 10');
    await tapPad(tester, '12.567');
    expect(cashShown(tester), 'KES 12.56');
    await tapPad(tester, '.');
    expect(cashShown(tester), 'KES 12.56'); // a second point is ignored
  });

  testWidgets(
    'the keyboard works without the mouse: digits, Backspace, Enter',
    (tester) async {
      await signInAs(tester, 'Jane Doe', '1357');
      await addFirstResult(tester);
      await tester.tap(find.byTooltip('One more'));
      await tester.pumpAndSettle();
      await openPay(tester, 'Pay KES 20');

      Future<void> type(String ch, LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(key, character: ch);
        await tester.sendKeyUpEvent(key);
        await tester.pump();
      }

      await type('5', LogicalKeyboardKey.digit5);
      await type('9', LogicalKeyboardKey.digit9);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(cashShown(tester), 'KES 5');

      // Enter with too little cash does nothing.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(PayDialog), findsOneWidget);

      await type('0', LogicalKeyboardKey.digit0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Sale complete'), findsOneWidget);
    },
  );

  testWidgets('Back to sale keeps the cart exactly as it was', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await openPay(tester, 'Pay KES 10');
    await tapPad(tester, '5');
    await tester.tap(find.text('Back to sale'));
    await tester.pumpAndSettle();
    expect(find.byType(PayDialog), findsNothing);
    expect(find.text('Pay KES 10'), findsOneWidget);
    expect(await tester.runAsync(() => db.select(db.sales).get()), isEmpty);
  });

  testWidgets('Escape also goes back to the sale', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await openPay(tester, 'Pay KES 10');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(PayDialog), findsNothing);
    expect(find.text('Pay KES 10'), findsOneWidget);
  });

  testWidgets(
    'if stock changed underneath, the panel explains and the cart survives',
    (tester) async {
      await signInAs(tester, 'Jane Doe', '1357');
      await addFirstResult(tester);
      await openPay(tester, 'Pay KES 10');
      // Someone else wrote the stock off while this sale was open.
      await tester.runAsync(
        () => db.customStatement('DELETE FROM stock_movements'),
      );
      await tester.tap(inPanel(find.text('Exact')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Complete sale'));
      await tester.pumpAndSettle();

      expect(find.byType(PayDialog), findsOneWidget);
      expect(find.textContaining('Not enough Paracetamol'), findsOneWidget);
      expect(await tester.runAsync(() => db.select(db.sales).get()), isEmpty);
      await tester.tap(find.text('Back to sale'));
      await tester.pumpAndSettle();
      // The screen now tells the truth about stock too.
      expect(find.text('Fix the lines marked in red first.'), findsOneWidget);
    },
  );

  testWidgets('a scanned barcode plus Enter adds the medicine', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await tester.enterText(
      field('Search name or scan barcode   (Ctrl+K)'),
      '6001',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 10'), findsOneWidget);
  });

  testWidgets('selling by the strip shows what leaves stock', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Strip').first);
    await tester.pumpAndSettle();
    expect(find.text('1 strip = 10 tablets'), findsOneWidget);
    expect(find.text('Pay KES 90'), findsOneWidget);
  });

  testWidgets('M-Pesa needs the code, then completes', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await openPay(tester, 'Pay KES 10');
    await tester.tap(inPanel(find.text('M-Pesa')));
    await tester.pumpAndSettle();
    final complete = find.widgetWithText(FilledButton, 'Complete sale');
    expect(tester.widget<FilledButton>(complete).onPressed, isNull);

    await tester.enterText(field('M-Pesa transaction code'), 'qgh7k2lmnp');
    await tester.pumpAndSettle();
    await tester.tap(complete);
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
    expect(find.text('Pay KES 90'), findsOneWidget);

    await tester.enterText(field('Approver’s PIN'), '8642'); // clinician
    await tester.tap(find.text('Apply discount'));
    await tester.pumpAndSettle();
    expect(find.textContaining('approved by Peter Njoroge'), findsOneWidget);
    expect(find.text('Pay KES 80'), findsOneWidget);

    await openPay(tester, 'Pay KES 80');
    expect(
      inPanel(find.textContaining('After a discount of KES 10')),
      findsOneWidget,
    );
    await tester.tap(inPanel(find.text('Exact')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Complete sale'));
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
    final pay = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Pay KES 30'),
    );
    expect(pay.onPressed, isNull);
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

      await tester.tap(find.text('Pay KES 10'));
      await tester.pumpAndSettle();
      expect(find.text('This sale includes expired stock'), findsOneWidget);
      await tester.tap(find.text('Go back'));
      await tester.pumpAndSettle();
      expect(find.byType(PayDialog), findsNothing);
      expect(await tester.runAsync(() => db.select(db.sales).get()), isEmpty);

      await tester.tap(find.text('Pay KES 10'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sell anyway'));
      await tester.pumpAndSettle();
      expect(find.byType(PayDialog), findsOneWidget);
      await tester.tap(inPanel(find.text('Exact')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Complete sale'));
      await tester.pumpAndSettle();
      expect(find.text('Sale complete'), findsOneWidget);
      expect(
        await tester.runAsync(() => db.select(db.sales).get()),
        hasLength(1),
      );
    },
  );

  testWidgets('Clear sale empties the cart', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    expect(find.text('1 item'), findsOneWidget);
    await tester.tap(find.text('Clear sale'));
    await tester.pumpAndSettle();
    expect(find.text('Nothing in the sale yet'), findsOneWidget);
  });

  testWidgets('the cart survives a visit to Stock', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 10'), findsOneWidget);
  });

  // ---- parking a sale ----------------------------------------------------

  Future<void> parkWithName(WidgetTester tester, [String? name]) async {
    await tester.tap(find.text('Park sale'));
    await tester.pumpAndSettle();
    if (name != null) {
      await tester.enterText(field('Name or note (optional)'), name);
    }
    await tester.tap(find.widgetWithText(FilledButton, 'Park sale'));
    await tester.pumpAndSettle();
  }

  testWidgets('park clears the sale; pick up brings it back', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.byTooltip('One more'));
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 20'), findsOneWidget);
    expect(find.textContaining('Parked ('), findsNothing);

    await parkWithName(tester, 'Mrs Achieng');
    expect(find.text('Nothing in the sale yet'), findsOneWidget);
    expect(find.textContaining('Sale parked'), findsOneWidget);
    expect(find.text('Parked (1)'), findsOneWidget);
    expect(find.text('Park sale'), findsNothing); // nothing to park now

    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Mrs Achieng'), findsOneWidget);
    expect(find.textContaining('Parked '), findsWidgets);
    expect(find.textContaining('by Jane Doe'), findsOneWidget);
    expect(find.textContaining('1 item'), findsWidgets);
    expect(find.textContaining('KES 20'), findsWidgets);

    await tester.tap(find.text('Pick up'));
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 20'), findsOneWidget);
    expect(find.text('2 tablets'), findsOneWidget);
    expect(find.textContaining('Parked ('), findsNothing); // it left the list
    expect(await tester.runAsync(() => db.select(db.sales).get()), isEmpty);
  });

  testWidgets('parking does not take stock', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await parkWithName(tester);
    expect(await tester.runAsync(() => db.stockOnHand(1)), 100);
  });

  testWidgets('a sale can only be picked up into an empty sale', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await parkWithName(tester, 'First');
    await addFirstResult(tester); // start another sale
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Park or finish the current sale'),
      findsOneWidget,
    );
    final pick = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Pick up'),
    );
    expect(pick.onPressed, isNull);
  });

  testWidgets('discard asks first, then forgets the sale', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await parkWithName(tester, 'Walked away');
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.text('Discard Walked away?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(
      await tester.runAsync(() => db.select(db.heldSales).get()),
      hasLength(1),
    );

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => db.select(db.heldSales).get()), isEmpty);
    expect(find.text('Nothing is parked.'), findsOneWidget);
  });

  testWidgets('an approved discount travels with the parked sale', (
    tester,
  ) async {
    await signInAs(
      tester,
      'Peter Njoroge',
      '8642',
    ); // clinician approves their own
    await addFirstResult(tester);
    await tester.tap(find.text('Strip').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add discount'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Discount amount'), '10');
    await tester.tap(find.text('Apply discount'));
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 80'), findsOneWidget);

    await parkWithName(tester, 'Discounted');
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('after discount'), findsOneWidget);
    await tester.tap(find.text('Pick up'));
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 80'), findsOneWidget);
    expect(find.textContaining('approved by Peter Njoroge'), findsOneWidget);
  });

  testWidgets('prices are checked again when a parked sale is picked up', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await parkWithName(tester);
    await tester.runAsync(
      () => stock.updateMedicine(
        med,
        const MedicineInput(
          name: 'Paracetamol 500mg',
          barcode: '6001',
          unitsPerStrip: 10,
          pricePerStripCents: 9000,
          pricePerUnitCents: 1500, // was 1000
        ),
      ),
    );
    // The screen reads stock when it loads; reopening it picks up the change.
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick up'));
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 15'), findsOneWidget);
  });

  testWidgets('stock is checked again too: not enough shows on the line', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.byTooltip('One more'));
    await tester.pump();
    await tester.tap(find.byTooltip('One more'));
    await tester.pumpAndSettle();
    await parkWithName(tester);
    await tester.runAsync(() async {
      await db.customStatement('DELETE FROM stock_movements');
      await db
          .into(db.stockMovements)
          .insert(
            StockMovementsCompanion.insert(
              batchId: 1,
              qtyDelta: 1,
              reason: MovementReason.receipt,
              createdBy: 1,
            ),
          );
    });
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick up'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Only 1 tablet in stock'), findsOneWidget);
    expect(find.text('Fix the lines marked in red first.'), findsOneWidget);
  });

  testWidgets('a medicine removed while parked is dropped, with a note', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await parkWithName(tester);
    await tester.runAsync(() => stock.setMedicineActive(med, false));
    await tester.tap(find.text('Stock'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pick up'));
    await tester.pumpAndSettle();
    expect(find.textContaining('no longer sold'), findsOneWidget);
    expect(find.text('Nothing in the sale yet'), findsOneWidget);
  });

  testWidgets('another person can pick up a sale that was parked', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await parkWithName(tester, 'For the next shift');

    await tester.pumpWidget(const SizedBox()); // Jane's session ends
    await tester.pumpAndSettle();
    await signInAs(tester, 'Peter Njoroge', '8642'); // a new session
    expect(find.text('Parked (1)'), findsOneWidget);
    await tester.tap(find.text('Parked (1)'));
    await tester.pumpAndSettle();
    expect(find.text('For the next shift'), findsOneWidget);
    expect(find.textContaining('by Jane Doe'), findsOneWidget);
    await tester.tap(find.text('Pick up'));
    await tester.pumpAndSettle();
    expect(find.text('Pay KES 10'), findsOneWidget);
  });

  testWidgets(
    'a parked sale is still there after the app is closed and reopened',
    (tester) async {
      await signInAs(tester, 'Jane Doe', '1357');
      await addFirstResult(tester);
      await parkWithName(tester, 'Overnight');

      await tester.pumpWidget(const SizedBox()); // close the app
      await tester.pumpAndSettle();
      await signInAs(tester, 'Jane Doe', '1357'); // open it again
      expect(find.text('Parked (1)'), findsOneWidget);
    },
  );

  testWidgets('a long name is refused with a plain message', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Park sale'));
    await tester.pumpAndSettle();
    // The box stops typing at the limit, so the sale parks with the first 40.
    await tester.enterText(field('Name or note (optional)'), 'x' * 60);
    await tester.tap(find.widgetWithText(FilledButton, 'Park sale'));
    await tester.pumpAndSettle();
    final row = (await tester.runAsync(
      () => db.select(db.heldSales).getSingle(),
    ))!;
    expect(row.label!.length, lessThanOrEqualTo(40));
  });

  // ---- choosing a patient ------------------------------------------------

  Future<void> registerPatient(WidgetTester tester, String name) async {
    await tester.runAsync(
      () => PatientService(
        db,
      ).register(PatientInput(fullName: name), userId: cashier.id),
    );
  }

  Future<void> finishCashSale(WidgetTester tester) async {
    await openPay(tester, 'Pay KES 10');
    await tester.tap(inPanel(find.text('Exact')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Complete sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New sale'));
    await tester.pumpAndSettle();
  }

  testWidgets('a sale for a chosen patient is linked to them, then cleared', (
    tester,
  ) async {
    await registerPatient(tester, 'Mary Wambui');
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);

    await tester.tap(find.text('Add patient'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Search name, phone or ID'), 'wamb');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mary Wambui'));
    await tester.pumpAndSettle();
    expect(find.text('Mary Wambui'), findsOneWidget);
    expect(find.text('Add patient'), findsNothing);

    await finishCashSale(tester);
    final sale = (await tester.runAsync(
      () => db.select(db.sales).getSingle(),
    ))!;
    final patient = (await tester.runAsync(
      () => db.select(db.patients).getSingle(),
    ))!;
    expect(sale.patientId, patient.id);

    // The next sale starts with nobody chosen.
    expect(find.text('Add patient'), findsOneWidget);
    await addFirstResult(tester);
    await finishCashSale(tester);
    final sales = (await tester.runAsync(() => db.select(db.sales).get()))!;
    expect(sales.last.patientId, isNull);
  });

  testWidgets('a patient can be removed from the sale before paying', (
    tester,
  ) async {
    await registerPatient(tester, 'Mary Wambui');
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Add patient'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mary Wambui'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Remove patient'));
    await tester.pumpAndSettle();
    await finishCashSale(tester);
    final sale = (await tester.runAsync(
      () => db.select(db.sales).getSingle(),
    ))!;
    expect(sale.patientId, isNull);
  });

  testWidgets('a new patient can be registered from the sale', (tester) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await addFirstResult(tester);
    await tester.tap(find.text('Add patient'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New patient'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Full name'), 'Peter Otieno');
    await tester.tap(find.widgetWithText(FilledButton, 'Register'));
    await tester.pumpAndSettle();

    expect(find.text('Peter Otieno'), findsOneWidget); // chosen for the sale
    await finishCashSale(tester);
    final sale = (await tester.runAsync(
      () => db.select(db.sales).getSingle(),
    ))!;
    expect(sale.patientId, isNotNull);
  });
}
