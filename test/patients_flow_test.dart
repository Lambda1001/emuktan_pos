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

/// Drives the real app: sign in, open Patients, register and open a record.
void main() {
  late AppDatabase db;
  late AuthService auth;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    await auth.createUser(
      displayName: 'Jane Doe',
      role: Role.cashier,
      pin: '1357',
    );
    await auth.createUser(
      displayName: 'Nurse Achieng',
      role: Role.clinician,
      pin: '2468',
    );
  });
  tearDown(() => db.close());

  Future<void> signInAs(WidgetTester tester, String name, String pin) async {
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
    await tester.tap(find.text(name));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), pin);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Patients'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> register(WidgetTester tester) async {
    await tester.tap(find.text('Register patient'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Full name'), 'Mary Wambui');
    await tester.enterText(field('Phone'), '0712345678');
    await tester.tap(find.widgetWithText(FilledButton, 'Register'));
    await tester.pumpAndSettle();
  }

  testWidgets('a cashier registers a patient and sees no clinical record', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    expect(find.text('No patients yet'), findsOneWidget);

    await register(tester);
    expect(find.text('Patient registered.'), findsOneWidget);
    expect(find.text('Mary Wambui'), findsOneWidget);

    await tester.tap(find.text('Mary Wambui'));
    await tester.pumpAndSettle();
    expect(find.text('0712345678'), findsWidgets);
    expect(find.text('Allergies'), findsNothing);
    expect(find.text('Record visit'), findsNothing);
  });

  testWidgets('a clinician records a visit and sees it in the record', (
    tester,
  ) async {
    await signInAs(tester, 'Nurse Achieng', '2468');
    await register(tester);

    await tester.tap(find.text('Mary Wambui'));
    await tester.pumpAndSettle();
    expect(find.text('Allergies'), findsOneWidget);
    expect(find.text('No visits recorded yet.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Record visit'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Weight (kg)'), '62.5');
    await tester.enterText(field('Notes'), 'Mild headache.');
    await tester.tap(find.widgetWithText(FilledButton, 'Save visit'));
    await tester.pumpAndSettle();

    expect(find.text('62.5 kg'), findsOneWidget);
    expect(find.text('Mild headache.'), findsOneWidget);
  });

  testWidgets('searching narrows the list and says when nothing matches', (
    tester,
  ) async {
    await signInAs(tester, 'Jane Doe', '1357');
    await register(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Search name, phone or ID'), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('Nothing matches'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Search name, phone or ID'), 'wamb');
    await tester.pumpAndSettle();
    expect(find.text('Mary Wambui'), findsOneWidget);
  });
}
