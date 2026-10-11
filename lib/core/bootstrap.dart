import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/backup_service.dart';
import '../data/database.dart';
import 'key_store.dart';

class AppContext {
  AppContext({
    required this.db,
    required this.dataDir,
    required this.newRecoveryKey,
    this.key,
    this.notice,
  });

  final AppDatabase db;
  final Directory dataDir;

  /// Non-null only on the very first run: the owner must record it.
  final String? newRecoveryKey;

  /// The database key, needed to prove backups open. Null only in tests that
  /// do not use backups.
  final Uint8List? key;

  /// Something the owner should read once at start-up, such as the result of
  /// a restore.
  final String? notice;
}

Future<Directory> defaultDataDir() async =>
    Directory(p.join((await getApplicationSupportDirectory()).path, 'Emuktan'));

KeyStore _storeFor(Directory dir) =>
    DpapiKeyStore(File(p.join(dir.path, 'db.key')));

/// Opens the encrypted database, creating the key on first run. If a restore
/// was scheduled, it is applied first, while nothing has the file open.
Future<AppContext> bootstrap({Directory? dataDir, KeyStore? keyStore}) async {
  final dir = dataDir ?? await defaultDataDir();
  await dir.create(recursive: true);
  final store = keyStore ?? _storeFor(dir);
  final loaded = await store.loadOrCreate();
  final Uint8List key = loaded.key;

  final notice = loaded.created ? null : await applyPendingRestore(dir, key);

  final db = AppDatabase.encrypted(File(p.join(dir.path, 'emuktan.db')), key);
  // Force the connection open now so a wrong key or missing SQLCipher fails
  // here, with a clear error, instead of on the first screen.
  await db.customSelect('SELECT 1').get();
  return AppContext(
    db: db,
    dataDir: dir,
    newRecoveryKey: loaded.created ? formatRecoveryKey(key) : null,
    key: key,
    notice: notice,
  );
}

/// What start-up needs to offer "restore from a backup" on a PC with no data.
/// Kept separate from [bootstrap] so tests can run without a real data folder.
class FirstRunHooks {
  const FirstRunHooks({required this.isFirstRun, required this.restore});

  /// True when this PC has no database and no key yet.
  final Future<bool> Function() isFirstRun;

  /// Brings a backup in using the printed recovery key. Throws
  /// [BackupException] with a plain message if it cannot.
  final Future<void> Function(String backupPath, String recoveryKey) restore;

  factory FirstRunHooks.real() => FirstRunHooks(
    isFirstRun: () async {
      final dir = await defaultDataDir();
      return !File(p.join(dir.path, 'db.key')).existsSync() &&
          !File(p.join(dir.path, 'emuktan.db')).existsSync();
    },
    restore: (backupPath, recoveryKey) async {
      final dir = await defaultDataDir();
      await restoreOnFreshPc(
        dir: dir,
        backup: File(backupPath.trim()),
        recoveryKey: recoveryKey,
        keyStore: _storeFor(dir),
      );
    },
  );
}
