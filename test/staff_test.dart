import 'package:drift/native.dart';
import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/features/staff/staff_screen.dart';
import 'package:emuktan_pos/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fast = PinHasher(iterations: 10);

  group('staff management rules', () {
    late AppDatabase db;
    late AuthService auth;
    late User owner, cashier;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      auth = AuthService(db, hasher: fast);
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

    test('allUsers lists active first, then inactive', () async {
      await auth.setActive(cashier.id, false, actingUserId: owner.id);
      final all = await auth.allUsers();
      expect(all.map((u) => u.id), [owner.id, cashier.id]);
      expect(all.last.active, isFalse);
    });

    test('edit changes name and role', () async {
      await auth.updateUser(
        cashier.id,
        displayName: '  Jane W. Doe ',
        role: Role.clinician,
      );
      final u = (await auth.allUsers()).firstWhere((x) => x.id == cashier.id);
      expect(u.displayName, 'Jane W. Doe');
      expect(u.role, Role.clinician);
    });

    test('the only owner cannot be demoted or deactivated', () async {
      await expectLater(
        auth.updateUser(
          owner.id,
          displayName: 'Wanjiru Kamau',
          role: Role.cashier,
        ),
        throwsA(isA<StaffRuleException>()),
      );
      await expectLater(
        auth.setActive(owner.id, false, actingUserId: cashier.id),
        throwsA(isA<StaffRuleException>()),
      );
    });

    test('with a second owner, the first can step down', () async {
      final second = await auth.createUser(
        displayName: 'Peter Njoroge',
        role: Role.owner,
        pin: '8642',
      );
      await auth.updateUser(
        owner.id,
        displayName: 'Wanjiru Kamau',
        role: Role.clinician,
      );
      // Now Peter is the last owner and is protected.
      await expectLater(
        auth.setActive(second.id, false, actingUserId: owner.id),
        throwsA(isA<StaffRuleException>()),
      );
    });

    test('nobody can deactivate themselves', () async {
      await auth.createUser(
        displayName: 'Peter Njoroge',
        role: Role.owner,
        pin: '8642',
      );
      await expectLater(
        auth.setActive(owner.id, false, actingUserId: owner.id),
        throwsA(isA<StaffRuleException>()),
      );
    });

    test(
      'deactivated user cannot sign in; reactivating restores access',
      () async {
        await auth.setActive(cashier.id, false, actingUserId: owner.id);
        expect(await auth.signIn(cashier.id, '1357'), isNull);
        await auth.setActive(cashier.id, true, actingUserId: owner.id);
        expect((await auth.signIn(cashier.id, '1357'))?.id, cashier.id);
      },
    );

    test(
      'reset PIN: old PIN stops working, new works, lockout lifted',
      () async {
        for (var i = 0; i < 5; i++) {
          await auth.signIn(cashier.id, '0000');
        }
        expect(auth.lockedSeconds(cashier.id), greaterThan(0));
        await auth.resetPin(cashier.id, '9753');
        expect(auth.lockedSeconds(cashier.id), 0);
        expect(await auth.signIn(cashier.id, '1357'), isNull);
        expect((await auth.signIn(cashier.id, '9753'))?.id, cashier.id);
      },
    );

    test('reset PIN enforces the PIN policy', () async {
      await expectLater(
        auth.resetPin(cashier.id, '1111'),
        throwsA(isA<PinPolicyException>()),
      );
    });

    test(
      'change own PIN needs the current PIN and a different new one',
      () async {
        await expectLater(
          auth.changeOwnPin(cashier.id, currentPin: '0000', newPin: '2468'),
          throwsA(isA<StaffRuleException>()),
        );
        await expectLater(
          auth.changeOwnPin(cashier.id, currentPin: '1357', newPin: '1357'),
          throwsA(isA<PinPolicyException>()),
        );
        await auth.changeOwnPin(cashier.id, currentPin: '1357', newPin: '2468');
        expect(await auth.signIn(cashier.id, '1357'), isNull);
        expect((await auth.signIn(cashier.id, '2468'))?.id, cashier.id);
      },
    );

    test('a missing account gives a plain message, not a crash', () async {
      await expectLater(
        auth.resetPin(999, '2468'),
        throwsA(isA<StaffRuleException>()),
      );
    });
  });

  group('Staff screen', () {
    late AppDatabase db;
    late AuthService auth;
    late User owner;

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1366, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [authServiceProvider.overrideWithValue(auth)],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: StaffScreen(me: owner),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      auth = AuthService(db, hasher: fast);
      owner = await auth.createUser(
        displayName: 'Wanjiru Kamau',
        role: Role.owner,
        pin: '4821',
      );
    });
    tearDown(() => db.close());

    testWidgets('owner adds a cashier and sees them listed', (tester) async {
      await pump(tester);
      expect(find.text('Wanjiru Kamau'), findsOneWidget);
      expect(find.textContaining('(you)'), findsOneWidget);

      await tester.tap(find.text('Add staff'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Jane Doe');
      await tester.enterText(fields.at(1), '1357');
      await tester.enterText(fields.at(2), '1357');
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(FilledButton, 'Add staff'),
        ),
      );
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Jane Doe'), findsOneWidget);
      expect(find.text('Staff member added.'), findsOneWidget);
    });

    testWidgets('mismatched PINs show a plain error and add nobody', (
      tester,
    ) async {
      await pump(tester);
      await tester.tap(find.text('Add staff'));
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'Jane Doe');
      await tester.enterText(fields.at(1), '1357');
      await tester.enterText(fields.at(2), '1358');
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.widgetWithText(FilledButton, 'Add staff'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('The two PINs do not match. Type them again.'),
        findsOneWidget,
      );
      expect((await tester.runAsync(auth.allUsers))!.length, 1);
    });

    testWidgets('own row has Deactivate disabled', (tester) async {
      await pump(tester);
      final btn = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Deactivate'),
      );
      expect(btn.onPressed, isNull);
    });
  });
}
