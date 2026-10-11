import 'dart:io';
import 'dart:typed_data';

import 'package:emuktan_pos/app_state.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/key_store.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/backup_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _key() =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + 1) & 0xff));

/// File work happens in real time but its continuations run in the test's
/// fake-async zone, so alternate real waiting with pumping until it is done.
Future<void> settleIO(WidgetTester tester) async {
  for (var i = 0; i < 25; i++) {
    await tester.runAsync(
      () => Future.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

/// Drives the real app on the Backup panel and the first-run screens, with a
/// real encrypted database in a temp folder.
void main() {
  late Directory root, data;
  late AppDatabase db;
  late AuthService auth;
  final key = _key();
  var exited = false;

  setUp(() async {
    exited = false;
    root = Directory.systemTemp.createTempSync('emuktan_bflow_');
    data = Directory(p.join(root.path, 'data'))..createSync();
    db = AppDatabase.encrypted(File(p.join(data.path, 'emuktan.db')), key);
    auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    await auth.createUser(
      displayName: 'Wanjiru Kamau',
      role: Role.owner,
      pin: '4821',
    );
  });
  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    FirstRunHooks? firstRun,
    String? notice,
    bool signIn = true,
  }) async {
    tester.view.physicalSize = const Size(1366, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(auth),
          appExitProvider.overrideWithValue(() async => exited = true),
        ],
        child: EmuktanApp(
          firstRun: firstRun,
          open: () async => AppContext(
            db: db,
            dataDir: data,
            newRecoveryKey: null,
            key: key,
            notice: notice,
          ),
        ),
      ),
    );
    // The automatic backup at start-up does real file work.
    await settleIO(tester);
    await tester.pumpAndSettle();
    if (!signIn) return;
    await tester.enterText(find.byType(TextField), '4821');
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
  }

  Future<void> openBackup(WidgetTester tester) async {
    await tester.tap(find.text('Staff and settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup').first);
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets(
    'a backup is taken automatically at start-up and shown in the status bar',
    (tester) async {
      await pumpApp(tester);
      expect(find.textContaining('Backed up today'), findsOneWidget);
      final files = Directory(p.join(data.path, 'backups')).listSync();
      expect(files, hasLength(1));
      // And it is a real, openable backup.
      verifyBackupFile(files.single as File, key);
    },
  );

  testWidgets('Back up now writes a checked backup to the chosen folder', (
    tester,
  ) async {
    await pumpApp(tester);
    await openBackup(tester);
    expect(find.textContaining('checked and readable'), findsOneWidget);

    final usb = p.join(root.path, 'usb');
    await tester.enterText(field('Backup folder'), usb);
    await tester.tap(find.text('Back up now'));
    await settleIO(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('Backup saved and checked'), findsOneWidget);
    expect(Directory(usb).listSync(), hasLength(1));
  });

  testWidgets(
    'a backup folder that is not there is explained, and the status bar warns',
    (tester) async {
      final blocker = File(p.join(root.path, 'blocker'))
        ..writeAsStringSync('x');
      await db
          .into(db.settings)
          .insert(
            SettingsCompanion.insert(
              key: 'backup.dir',
              value: p.join(blocker.path, 'inside'),
            ),
          );
      await pumpApp(tester);
      expect(find.text('Backup failed'), findsOneWidget);

      await openBackup(tester);
      expect(find.textContaining('The last backup failed'), findsOneWidget);
      expect(find.textContaining('not available'), findsWidgets);
      expect(find.text('Needs attention'), findsOneWidget);
    },
  );

  testWidgets(
    'the recovery key check accepts the real key and rejects others',
    (tester) async {
      await pumpApp(tester);
      await openBackup(tester);
      await tester.ensureVisible(field('Recovery key from your printed copy'));
      await tester.enterText(
        field('Recovery key from your printed copy'),
        'abcd-1234',
      );
      await tester.tap(find.text('Check key'));
      await tester.pumpAndSettle();
      expect(find.textContaining('does not match'), findsOneWidget);

      await tester.enterText(
        field('Recovery key from your printed copy'),
        formatRecoveryKey(key),
      );
      await tester.tap(find.text('Check key'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This is the right key'), findsOneWidget);
    },
  );

  testWidgets(
    'Restore asks first, schedules the restore, then closes the app',
    (tester) async {
      await pumpApp(tester);
      await openBackup(tester);

      await tester.ensureVisible(find.text('Restore').first);
      await tester.tap(find.text('Restore').first);
      await tester.pumpAndSettle();
      expect(find.text('Restore this backup?'), findsOneWidget);
      expect(find.textContaining('kept as a safety copy'), findsOneWidget);

      // Cancel changes nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(File(p.join(data.path, 'restore.pending')).existsSync(), isFalse);
      expect(exited, isFalse);

      await tester.tap(find.text('Restore').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore and close'));
      await settleIO(tester);
      await tester.pumpAndSettle();
      expect(File(p.join(data.path, 'restore.pending')).existsSync(), isTrue);
      expect(exited, isTrue);
    },
  );

  testWidgets(
    'restoring from a file that is not a backup is refused in the dialog',
    (tester) async {
      final junk = File(p.join(root.path, 'junk.db'))
        ..writeAsStringSync('x' * 4000);
      await pumpApp(tester);
      await openBackup(tester);
      await tester.tap(find.text('Restore from a file\u2026'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Backup file'), junk.path);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore and close'));
      await settleIO(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('recovery key is wrong'), findsOneWidget);
      expect(exited, isFalse);
      expect(File(p.join(data.path, 'restore.pending')).existsSync(), isFalse);
    },
  );

  group('first run on a new PC', () {
    testWidgets('a wrong recovery key shows the reason and stays on the form', (
      tester,
    ) async {
      final hooks = FirstRunHooks(
        isFirstRun: () async => true,
        restore: (path, k) async => throw BackupException(
          'This file could not be opened with this key. It is not an Emuktan backup, '
          'or the recovery key is wrong.',
        ),
      );
      await pumpApp(tester, firstRun: hooks, signIn: false);
      expect(find.text('Welcome'), findsOneWidget);
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Backup file'), r'E:\backups\x.db');
      await tester.enterText(field('Recovery key'), 'wrong');
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await tester.pumpAndSettle();
      expect(find.textContaining('recovery key is wrong'), findsOneWidget);
      expect(find.text('Restore from a backup'), findsOneWidget); // still here
    });

    testWidgets('a good restore carries on to sign-in', (tester) async {
      var restored = false;
      final hooks = FirstRunHooks(
        isFirstRun: () async => !restored,
        restore: (path, k) async => restored = true,
      );
      await pumpApp(tester, firstRun: hooks, signIn: false);
      await tester.tap(find.text('Restore from a backup'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Backup file'), r'E:\backups\x.db');
      await tester.enterText(field('Recovery key'), formatRecoveryKey(key));
      await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
      await settleIO(tester);
      await tester.pumpAndSettle();
      expect(restored, isTrue);
      expect(
        find.text('Hello, Wanjiru Kamau'),
        findsOneWidget,
      ); // normal sign-in
    });

    testWidgets('"Set up a new shop" goes on to the normal start', (
      tester,
    ) async {
      final hooks = FirstRunHooks(
        isFirstRun: () async => true,
        restore: (_, _) async {},
      );
      await pumpApp(tester, firstRun: hooks, signIn: false);
      await tester.tap(find.text('Set up a new shop'));
      await settleIO(tester);
      await tester.pumpAndSettle();
      expect(find.text('Hello, Wanjiru Kamau'), findsOneWidget);
    });
  });

  testWidgets('a restore result is shown once, then sign-in follows', (
    tester,
  ) async {
    await pumpApp(
      tester,
      notice: 'Your data was restored from emuktan-20261010-143000.db.',
      signIn: false,
    );
    expect(find.textContaining('Your data was restored from'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Hello, Wanjiru Kamau'), findsOneWidget);
  });
}
