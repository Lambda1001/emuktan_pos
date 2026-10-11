import 'dart:io';
import 'dart:typed_data';

import 'package:emuktan_pos/config/app_config.dart';
import 'package:emuktan_pos/core/bootstrap.dart';
import 'package:emuktan_pos/core/key_store.dart';
import 'package:emuktan_pos/data/backup_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xff));

/// A key store that lives in memory, so tests do not need Windows DPAPI.
class _MemoryKeyStore implements KeyStore {
  Uint8List? key;
  bool failRestore = false;

  @override
  Future<({Uint8List key, bool created})> loadOrCreate() async {
    if (key != null) return (key: key!, created: false);
    key = _key(99);
    return (key: key!, created: true);
  }

  @override
  Future<void> restore(Uint8List k) async {
    if (failRestore) throw const FileSystemException('disk full');
    key = k;
  }
}

Future<void> _addUser(AppDatabase db, String name) => db
    .into(db.users)
    .insert(
      UsersCompanion.insert(
        username: name.toLowerCase(),
        displayName: name,
        role: Role.owner,
        secretHash: 'h',
        secretSalt: 's',
      ),
    );

void main() {
  late Directory root;
  late Directory data;
  late Directory backups;
  late AppDatabase db;
  late BackupService svc;
  var now = DateTime(2026, 10, 10, 14, 30, 0);
  final key = _key(1);

  setUp(() async {
    now = DateTime(2026, 10, 10, 14, 30, 0);
    root = Directory.systemTemp.createTempSync('emuktan_backup_');
    data = Directory(p.join(root.path, 'data'))..createSync();
    backups = Directory(p.join(root.path, 'usb'));
    db = AppDatabase.encrypted(File(p.join(data.path, 'emuktan.db')), key);
    await _addUser(db, 'Wanjiru');
    svc = BackupService(db, data, key, clock: () => now);
    await svc.setFolder(backups.path);
  });
  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  group('verifying a backup file', () {
    test(
      'a real backup opens with its key and reports what is in it',
      () async {
        final b = await svc.backupNow();
        final info = verifyBackupFile(b.file, key);
        expect(info.userCount, 1);
        expect(info.schemaVersion, AppDatabase.currentSchemaVersion);
      },
    );

    test('the wrong key is refused with a plain message', () async {
      final b = await svc.backupNow();
      expect(
        () => verifyBackupFile(b.file, _key(2)),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('recovery key is wrong'),
          ),
        ),
      );
    });

    test('a file that is not a database is refused', () {
      final junk = File(p.join(root.path, 'junk.db'))
        ..writeAsStringSync('this is not a database, just some text' * 50);
      expect(
        () => verifyBackupFile(junk, key),
        throwsA(isA<BackupException>()),
      );
    });

    test('a missing file is refused', () {
      expect(
        () => verifyBackupFile(File(p.join(root.path, 'nope.db')), key),
        throwsA(isA<BackupException>()),
      );
    });

    test('a truncated backup is refused', () async {
      final b = await svc.backupNow();
      final bytes = b.file.readAsBytesSync();
      final cut = File(p.join(root.path, 'cut.db'))
        ..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      expect(() => verifyBackupFile(cut, key), throwsA(isA<BackupException>()));
    });

    test('the backup does not contain readable data', () async {
      final b = await svc.backupNow();
      final text = String.fromCharCodes(b.file.readAsBytesSync());
      expect(text.contains('Wanjiru'), isFalse);
      expect(text.startsWith('SQLite format 3'), isFalse);
    });
  });

  group('taking backups', () {
    test(
      'backupNow writes a named file, records it, and creates the folder',
      () async {
        expect(backups.existsSync(), isFalse);
        final b = await svc.backupNow();
        expect(b.name, 'emuktan-20261010-143000.db');
        expect(b.file.existsSync(), isTrue);
        final s = await svc.status();
        expect(s.lastAt, now);
        expect(s.lastError, isNull);
        expect(s.lastFile, b.file.path);
      },
    );

    test('runIfDue backs up when none exists, then waits a day', () async {
      expect(await svc.runIfDue(), isNotNull);
      now = now.add(const Duration(hours: 3));
      expect(await svc.runIfDue(), isNull);
      expect(await svc.list(), hasLength(1));
      now = now.add(const Duration(hours: 22));
      expect(await svc.runIfDue(), isNotNull);
      expect(await svc.list(), hasLength(2));
    });

    test('only the newest backups are kept', () async {
      for (var i = 0; i < BackupConfig.keep + 3; i++) {
        now = now.add(const Duration(days: 1));
        await svc.backupNow();
      }
      final kept = await svc.list();
      expect(kept, hasLength(BackupConfig.keep));
      expect(kept.first.takenAt, now); // newest first
    });

    test('pruning never touches files that are not backups', () async {
      backups.createSync(recursive: true);
      final mine = File(p.join(backups.path, 'holiday-photos.db'))
        ..writeAsStringSync('keep me');
      for (var i = 0; i < BackupConfig.keep + 2; i++) {
        now = now.add(const Duration(days: 1));
        await svc.backupNow();
      }
      expect(mine.existsSync(), isTrue);
    });

    test(
      'an unusable folder gives a plain message, records it, and leaves no file',
      () async {
        // A file where the folder should be.
        final blocker = File(p.join(root.path, 'blocker'))
          ..writeAsStringSync('x');
        await svc.setFolder(p.join(blocker.path, 'inside'));
        await expectLater(
          svc.backupNow(),
          throwsA(
            isA<BackupException>().having(
              (e) => e.message,
              'message',
              contains('not available'),
            ),
          ),
        );
        expect((await svc.status()).lastError, contains('not available'));
        expect((await svc.status()).lastAt, isNull);
      },
    );

    test('runIfDue reports failure by recording it, not by throwing', () async {
      final blocker = File(p.join(root.path, 'blocker'))
        ..writeAsStringSync('x');
      await svc.setFolder(p.join(blocker.path, 'inside'));
      expect(await svc.runIfDue(), isNull);
      expect((await svc.status()).lastError, isNotNull);
    });

    test('a later success clears the recorded failure', () async {
      final blocker = File(p.join(root.path, 'blocker'))
        ..writeAsStringSync('x');
      await svc.setFolder(p.join(blocker.path, 'inside'));
      await svc.runIfDue();
      await svc.setFolder(backups.path);
      await svc.backupNow();
      expect((await svc.status()).lastError, isNull);
    });

    test('staleness: none, recent, old', () async {
      expect((await svc.status()).isStale(now), isTrue);
      await svc.backupNow();
      expect((await svc.status()).isStale(now), isFalse);
      expect(
        (await svc.status()).isStale(
          now.add(BackupConfig.staleAfter + const Duration(minutes: 1)),
        ),
        isTrue,
      );
    });

    test('warns when backups share a drive with the data', () async {
      await svc.setFolder(p.join(data.path, 'backups'));
      expect(await svc.folderSharesDriveWithData(), isTrue);
    });
  });

  group('recovery key check', () {
    test('accepts the real key in any tidy form, rejects others', () {
      final text = formatRecoveryKey(key);
      expect(svc.recoveryKeyMatches(text), isTrue);
      expect(
        svc.recoveryKeyMatches(text.toUpperCase().replaceAll('-', ' ')),
        isTrue,
      );
      expect(svc.recoveryKeyMatches(formatRecoveryKey(_key(2))), isFalse);
      expect(svc.recoveryKeyMatches('nonsense'), isFalse);
      expect(svc.recoveryKeyMatches(''), isFalse);
    });
  });

  group('restoring on the same PC', () {
    test(
      'a scheduled restore swaps the data in at the next start and keeps the old',
      () async {
        final b = await svc.backupNow(); // contains Wanjiru only
        await _addUser(db, 'Added After Backup');
        await scheduleRestore(data, b.file, key);
        await db.close();

        final notice = await applyPendingRestore(data, key, now: now);
        expect(
          notice,
          contains('was restored from emuktan-20261010-143000.db'),
        );
        expect(
          data.listSync().any(
            (e) => p.basename(e.path).startsWith('emuktan.db.before-restore-'),
          ),
          isTrue,
        );
        expect(
          File(p.join(data.path, 'restore.pending')).existsSync(),
          isFalse,
        );

        db = AppDatabase.encrypted(File(p.join(data.path, 'emuktan.db')), key);
        final names = (await db.select(db.users).get()).map(
          (u) => u.displayName,
        );
        expect(names, ['Wanjiru']); // the later user is gone
      },
    );

    test('the safety copy still holds the newer data', () async {
      final b = await svc.backupNow();
      await _addUser(db, 'Added After Backup');
      await scheduleRestore(data, b.file, key);
      await db.close();
      await applyPendingRestore(data, key, now: now);
      final kept = data.listSync().firstWhere(
        (e) => p.basename(e.path).startsWith('emuktan.db.before-restore-'),
      );
      final old = AppDatabase.encrypted(File(kept.path), key);
      expect((await old.select(old.users).get()), hasLength(2));
      await old.close();
      db = AppDatabase.encrypted(File(p.join(data.path, 'emuktan.db')), key);
    });

    test('scheduling refuses a bad file straight away', () async {
      final junk = File(p.join(root.path, 'junk.db'))
        ..writeAsStringSync('x' * 3000);
      await expectLater(
        scheduleRestore(data, junk, key),
        throwsA(isA<BackupException>()),
      );
      expect(File(p.join(data.path, 'restore.pending')).existsSync(), isFalse);
    });

    test(
      'a backup that turns bad before restart leaves the data unchanged',
      () async {
        final b = await svc.backupNow();
        await scheduleRestore(data, b.file, key);
        b.file.deleteSync(); // drive unplugged before the next start
        await db.close();

        final notice = await applyPendingRestore(data, key, now: now);
        expect(notice, contains('did not happen and your data is unchanged'));
        db = AppDatabase.encrypted(File(p.join(data.path, 'emuktan.db')), key);
        expect(await db.select(db.users).get(), hasLength(1));
      },
    );

    test(
      'start-up applies a scheduled restore before opening the database',
      () async {
        final b = await svc.backupNow();
        await _addUser(db, 'Added After Backup');
        await scheduleRestore(data, b.file, key);
        await db.close();

        final ctx = await bootstrap(
          dataDir: data,
          keyStore: _MemoryKeyStore()..key = key,
        );
        expect(ctx.notice, contains('was restored from'));
        expect(ctx.newRecoveryKey, isNull);
        final names = (await ctx.db.select(ctx.db.users).get()).map(
          (u) => u.displayName,
        );
        expect(names, ['Wanjiru']);
        await ctx.db.close();

        // A second start shows no notice: it was one-time.
        final again = await bootstrap(
          dataDir: data,
          keyStore: _MemoryKeyStore()..key = key,
        );
        expect(again.notice, isNull);
        await again.db.close();
        db = AppDatabase.encrypted(File(p.join(data.path, 'emuktan.db')), key);
      },
    );

    test('no marker, no restore', () async {
      expect(await applyPendingRestore(data, key), isNull);
    });
  });

  group('restoring on a new PC with the recovery key', () {
    late Directory fresh;
    setUp(() => fresh = Directory(p.join(root.path, 'newpc')));

    test(
      'the old backup opens on a PC that has only the recovery key',
      () async {
        await _addUser(db, 'Peter');
        final b = await svc.backupNow();
        final printed = formatRecoveryKey(key);

        final store = _MemoryKeyStore(); // new PC: no key yet
        await restoreOnFreshPc(
          dir: fresh,
          backup: b.file,
          recoveryKey: printed,
          keyStore: store,
        );
        expect(store.key, key);

        final ctx = await bootstrap(dataDir: fresh, keyStore: store);
        expect(ctx.newRecoveryKey, isNull); // not a "new" install
        final names = (await ctx.db.select(ctx.db.users).get()).map(
          (u) => u.displayName,
        );
        expect(names, containsAll(['Wanjiru', 'Peter']));
        await ctx.db.close();
      },
    );

    test('a wrong recovery key restores nothing and saves no key', () async {
      final b = await svc.backupNow();
      final store = _MemoryKeyStore();
      await expectLater(
        restoreOnFreshPc(
          dir: fresh,
          backup: b.file,
          recoveryKey: formatRecoveryKey(_key(2)),
          keyStore: store,
        ),
        throwsA(isA<BackupException>()),
      );
      expect(store.key, isNull);
      expect(File(p.join(fresh.path, 'emuktan.db')).existsSync(), isFalse);
    });

    test('a mistyped recovery key is explained, not a crash', () async {
      final b = await svc.backupNow();
      await expectLater(
        restoreOnFreshPc(
          dir: fresh,
          backup: b.file,
          recoveryKey: 'abc',
          keyStore: _MemoryKeyStore(),
        ),
        throwsA(
          isA<BackupException>().having(
            (e) => e.message,
            'message',
            contains('not a recovery key'),
          ),
        ),
      );
    });

    test('if the key cannot be saved, no database is left behind', () async {
      final b = await svc.backupNow();
      final store = _MemoryKeyStore()..failRestore = true;
      await expectLater(
        restoreOnFreshPc(
          dir: fresh,
          backup: b.file,
          recoveryKey: formatRecoveryKey(key),
          keyStore: store,
        ),
        throwsA(isA<BackupException>()),
      );
      expect(File(p.join(fresh.path, 'emuktan.db')).existsSync(), isFalse);
    });
  });
}
