import 'dart:io';

import 'package:drift/native.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the real EmuktanApp (same widget tree as production), so problems
/// that only appear with the real provider scope / navigator layout show up.
void main() {
  testWidgets('first run: set up owner, open Staff, dialogs can open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(
      ProviderScope(
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
    expect(find.text('Set up the owner account'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Wanjiru Kamau');
    await tester.enterText(fields.at(1), '4821');
    await tester.enterText(fields.at(2), '4821');
    // Real PBKDF2 cost runs here, so let real time pass.
    await tester.runAsync(() async {
      await tester.tap(find.text('Create owner account'));
      await Future.delayed(const Duration(seconds: 2));
    });
    await tester.pumpAndSettle();

    expect(find.text('Staff and settings'), findsOneWidget);
    await tester.tap(find.text('Staff and settings'));
    await tester.pumpAndSettle();

    // The exact path that crashed with "No ProviderScope found".
    await tester.tap(find.text('Add staff'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Change PIN dialog from the status bar uses the same scope.
    await tester.tap(find.text('Change PIN'));
    await tester.pumpAndSettle();
    expect(find.text('Change your PIN'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
