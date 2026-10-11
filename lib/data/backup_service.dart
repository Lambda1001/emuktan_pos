import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

import '../config/app_config.dart';
import '../core/key_store.dart';
import 'database.dart';

/// A backup problem, with a message written for the owner.
class BackupException implements Exception {
  BackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What is known about a backup file after opening it.
class BackupInfo {
  const BackupInfo({required this.schemaVersion, required this.userCount});
  final int schemaVersion;
  final int userCount;
}

/// Opens [file] with [key] and checks it is a sound Emuktan database. Never
/// changes the file. Throws [BackupException] if it is not usable.
BackupInfo verifyBackupFile(File file, List<int> key) {
  if (!file.existsSync()) {
    throw BackupException('The backup file was not found: ${file.path}');
  }
  sql.Database? raw;
  try {
    raw = sql.sqlite3.open(file.path, mode: sql.OpenMode.readOnly);
    applyKey(raw, key); // throws if SQLCipher is missing or the key is wrong
    final check = raw.select('PRAGMA integrity_check;').first.values.first;
    if ('$check' != 'ok') {
      throw BackupException('This backup file is damaged ($check).');
    }
    final version =
        raw.select('PRAGMA user_version;').first.values.first as int;
    if (version > AppDatabase.currentSchemaVersion) {
      throw BackupException(
        'This backup was made by a newer version of Emuktan. Update Emuktan first.',
      );
    }
    final users =
        raw.select('SELECT count(*) FROM users;').first.values.first as int;
    return BackupInfo(schemaVersion: version, userCount: users);
  } on BackupException {
    rethrow;
  } on WrongDatabaseKeyException {
    throw BackupException(
      'This file could not be opened with this key. It is not an Emuktan backup, '
      'or the recovery key is wrong.',
    );
  } on sql.SqliteException {
    throw BackupException(
      'This file could not be opened with this key. It is not an Emuktan backup, '
      'or the recovery key is wrong.',
    );
  } finally {
    try {
      raw?.close();
    } catch (_) {}
  }
}

/// Backups are named so they sort by date and are easy to recognise.
final _backupName = RegExp(r'^emuktan-(\d{8})-(\d{6})\.db$');

class BackupFile {
  const BackupFile(this.file, this.takenAt, this.bytes);
  final File file;
  final DateTime takenAt;
  final int bytes;
  String get name => p.basename(file.path);
}

class BackupStatus {
  const BackupStatus({this.lastAt, this.lastFile, this.lastError});
  final DateTime? lastAt;
  final String? lastFile, lastError;

  bool isStale(DateTime now) =>
      lastAt == null || now.difference(lastAt!) > BackupConfig.staleAfter;
}

/// Taking backups: on demand, on a schedule, with a check that each one opens.
class BackupService {
  BackupService(this._db, this.dataDir, this._key, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final Directory dataDir;
  final Uint8List _key;
  final DateTime Function() _now;

  static const _kDir = 'backup.dir';
  static const _kLastAt = 'backup.lastAt';
  static const _kLastFile = 'backup.lastFile';
  static const _kLastError = 'backup.lastError';

  /// Where backups go when the owner has not chosen a folder.
  String get defaultFolder => p.join(dataDir.path, 'backups');

  Future<String?> _get(String key) async => (await (_db.select(
    _db.settings,
  )..where((s) => s.key.equals(key))).getSingleOrNull())?.value;

  Future<void> _set(String key, String? value) async {
    if (value == null) {
      await (_db.delete(_db.settings)..where((s) => s.key.equals(key))).go();
    } else {
      await _db
          .into(_db.settings)
          .insertOnConflictUpdate(
            SettingsCompanion.insert(key: key, value: value),
          );
    }
  }

  Future<String> folder() async => await _get(_kDir) ?? defaultFolder;

  Future<void> setFolder(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) throw BackupException('Enter a folder for backups.');
    await _set(_kDir, trimmed);
  }

  /// True when backups would sit on the same drive as the data, so one failed
  /// disk would lose both.
  Future<bool> folderSharesDriveWithData() async {
    final a = p.rootPrefix(p.absolute(await folder())).toLowerCase();
    final b = p.rootPrefix(p.absolute(dataDir.path)).toLowerCase();
    return a == b;
  }

  Future<BackupStatus> status() async {
    final at = await _get(_kLastAt);
    return BackupStatus(
      lastAt: at == null ? null : DateTime.tryParse(at),
      lastFile: await _get(_kLastFile),
      lastError: await _get(_kLastError),
    );
  }

  String _stamp(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}${two(d.month)}${two(d.day)}-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  /// Writes a backup, proves it opens, records it, and trims old ones.
  /// On any failure the broken file is removed, the failure is recorded for
  /// the status bar, and a [BackupException] is thrown.
  Future<BackupFile> backupNow() async {
    final dir = Directory(await folder());
    final now = _now();
    final target = File(p.join(dir.path, 'emuktan-${_stamp(now)}.db'));
    try {
      try {
        await dir.create(recursive: true);
      } on FileSystemException {
        throw BackupException(
          'The backup folder is not available (${dir.path}). '
          'Plug in the drive, or choose another folder.',
        );
      }
      try {
        await _db.backupTo(target.path);
      } catch (e) {
        throw BackupException(
          'The backup could not be written to ${dir.path}. $e',
        );
      }
      verifyBackupFile(target, _key);
      await _set(_kLastAt, now.toIso8601String());
      await _set(_kLastFile, target.path);
      await _set(_kLastError, null);
      await _prune(dir);
      return BackupFile(target, now, target.lengthSync());
    } on BackupException catch (e) {
      try {
        if (target.existsSync()) target.deleteSync();
      } catch (_) {}
      await _set(_kLastError, e.message);
      rethrow;
    }
  }

  /// Takes a backup if the last one is older than [BackupConfig.every].
  /// Returns the new backup, or null when none was due or it failed (the
  /// failure is recorded and shown in the status bar, not thrown).
  Future<BackupFile?> runIfDue() async {
    final last = (await status()).lastAt;
    if (last != null && _now().difference(last) < BackupConfig.every) {
      return null;
    }
    try {
      return await backupNow();
    } on BackupException {
      return null;
    }
  }

  Future<List<BackupFile>> list([String? folderPath]) async {
    final dir = Directory(folderPath ?? await folder());
    if (!dir.existsSync()) return const [];
    final out = <BackupFile>[];
    for (final e in dir.listSync().whereType<File>()) {
      final m = _backupName.firstMatch(p.basename(e.path));
      if (m == null) continue;
      final d = m.group(1)!, t = m.group(2)!;
      out.add(
        BackupFile(
          e,
          DateTime(
            int.parse(d.substring(0, 4)),
            int.parse(d.substring(4, 6)),
            int.parse(d.substring(6, 8)),
            int.parse(t.substring(0, 2)),
            int.parse(t.substring(2, 4)),
            int.parse(t.substring(4, 6)),
          ),
          e.lengthSync(),
        ),
      );
    }
    out.sort((a, b) => b.takenAt.compareTo(a.takenAt));
    return out;
  }

  Future<void> _prune(Directory dir) async {
    final all = await list(dir.path);
    for (final old in all.skip(BackupConfig.keep)) {
      try {
        old.file.deleteSync();
      } catch (_) {}
    }
  }

  /// Does [typed] match the key this database is using? Lets the owner prove
  /// their printed recovery key is right while nothing is wrong.
  bool recoveryKeyMatches(String typed) {
    try {
      final k = parseRecoveryKey(typed);
      var diff = 0;
      for (var i = 0; i < k.length; i++) {
        diff |= k[i] ^ _key[i];
      }
      return diff == 0;
    } on FormatException {
      return false;
    }
  }
}

// ---- Restoring ----------------------------------------------------------

const _pendingName = 'restore.pending';
const _dbName = 'emuktan.db';

/// Replaces the database file with [backup], keeping the old one beside it.
/// Nothing is changed unless the backup opens with [key].
Future<File> _swapIn(
  Directory dir,
  File backup,
  Uint8List key,
  DateTime now,
) async {
  verifyBackupFile(backup, key);
  final live = File(p.join(dir.path, _dbName));
  final tmp = File(p.join(dir.path, '$_dbName.restoring'));
  if (tmp.existsSync()) tmp.deleteSync();
  await backup.copy(tmp.path);
  File? kept;
  if (live.existsSync()) {
    kept = File(
      p.join(dir.path, '$_dbName.before-restore-${now.millisecondsSinceEpoch}'),
    );
    await live.rename(kept.path);
  }
  try {
    await tmp.rename(live.path);
  } catch (_) {
    if (kept != null && !live.existsSync()) await kept.rename(live.path);
    rethrow;
  }
  return kept ?? live;
}

/// Asks the next start-up to restore [backup]. The running database stays
/// open and untouched until then, so a restore can never half-happen.
Future<void> scheduleRestore(Directory dir, File backup, Uint8List key) async {
  verifyBackupFile(backup, key); // refuse now, not at next start
  await File(p.join(dir.path, _pendingName)).writeAsString(backup.path);
}

/// Called by start-up before the database opens. Returns a message to show
/// the owner, or null if no restore was waiting.
Future<String?> applyPendingRestore(
  Directory dir,
  Uint8List key, {
  DateTime? now,
}) async {
  final marker = File(p.join(dir.path, _pendingName));
  if (!marker.existsSync()) return null;
  final path = (await marker.readAsString()).trim();
  await marker.delete();
  try {
    final kept = await _swapIn(dir, File(path), key, now ?? DateTime.now());
    return 'Your data was restored from ${p.basename(path)}. '
        'The data you had before was kept as ${p.basename(kept.path)} in the Emuktan data folder.';
  } on BackupException catch (e) {
    return 'The restore did not happen and your data is unchanged. ${e.message}';
  } catch (e) {
    return 'The restore did not happen and your data is unchanged. $e';
  }
}

/// Disaster recovery on a PC with no data: bring a backup in using the
/// printed recovery key. Installs that key for this PC (wrapped by this
/// Windows account) so the restored data opens normally afterwards.
Future<void> restoreOnFreshPc({
  required Directory dir,
  required File backup,
  required String recoveryKey,
  required KeyStore keyStore,
  DateTime? now,
}) async {
  final Uint8List key;
  try {
    key = parseRecoveryKey(recoveryKey);
  } on FormatException {
    throw BackupException(
      'That is not a recovery key. It is 64 letters and digits, shown in 8 groups.',
    );
  }
  await dir.create(recursive: true);
  await _swapIn(dir, backup, key, now ?? DateTime.now());
  try {
    await keyStore.restore(key);
  } catch (e) {
    // A database with no matching key on file is worse than none: undo.
    final live = File(p.join(dir.path, _dbName));
    if (live.existsSync()) live.deleteSync();
    throw BackupException('The recovery key could not be saved on this PC. $e');
  }
}
