import 'dart:io';

import 'package:drift/native.dart';
import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late AuthService auth;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
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

  testWidgets('the owner opens Reports and switches between its tabs', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authServiceProvider.overrideWithValue(auth)],
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
    await tester.tap(find.text('Wanjiru Kamau'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '4821');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('Time clock'), findsNothing);
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();
    expect(find.text('No sales in this period'), findsOneWidget);

    await tester.tap(find.text('Last 7 days'));
    await tester.pumpAndSettle();
    expect(find.text('No sales in this period'), findsOneWidget);

    // The sidebar also says Stock; the tab comes later in the tree.
    await tester.tap(find.text('Stock').last);
    await tester.pumpAndSettle();
    expect(find.text('No medicines yet'), findsOneWidget);
  });
}
