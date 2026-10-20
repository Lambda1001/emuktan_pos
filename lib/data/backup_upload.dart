import 'dart:async';
import 'dart:io';


import 'backup_service.dart';
import 'database.dart';
import 'sync_service.dart';

enum UploadOutcome {
  /// The newest backup reached the server and the server stored every byte.
  sent,

  /// No backup yet, or the newest one was already sent.
  nothingToSend,

  /// Dashboard settings are not filled in.
  notConfigured,

  /// Could not reach the server: normal when the connection is down.
  offline,

  /// The server answered but refused, or stored the wrong amount.
  rejected,

  /// An upload was already running.
  busy,
}

class UploadResult {
  const UploadResult(this.outcome, {this.name, this.message});
  final UploadOutcome outcome;
  final String? name, message;
}

/// The offsite copy: which backup the server last stored.
class OffsiteStatus {
  const OffsiteStatus({this.name, this.sentAt, this.error});
  final String? name;
  final DateTime? sentAt;
  final String? error;
}

/// Sends the newest local backup to the dashboard server (`POST /api/backup`),
/// using the same address and key as sync. The file is already encrypted with
/// the clinic's key on this PC; the server stores it without opening it, so
/// patient records are never readable there. It keeps the newest 14.
class BackupUploader {
  BackupUploader(
    this._db,
    this._backups,
    this._sync, {
    SyncTransport? transport,
    DateTime Function()? clock,
  }) : _transport = transport ?? HttpSyncTransport(),
       _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final BackupService _backups;
  final SyncService _sync;
  final SyncTransport _transport;
  final DateTime Function() _now;
  bool _running = false;

  static const _kName = 'backup.offsiteName';
  static const _kAt = 'backup.offsiteAt';
  static const _kError = 'backup.offsiteError';

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

  Future<OffsiteStatus> status() async {
    final at = await _get(_kAt);
    return OffsiteStatus(
      name: await _get(_kName),
      sentAt: at == null ? null : DateTime.tryParse(at),
      error: await _get(_kError),
    );
  }

  /// Is there a local backup the server has not stored yet?
  Future<bool> hasUnsent() async {
    final newest = (await _backups.list()).firstOrNull;
    return newest != null && newest.name != await _get(_kName);
  }

  /// Sends the newest backup unless it was already sent. Never throws:
  /// problems are returned and recorded for the settings screen. Safe to call
  /// often; it does nothing when there is nothing new.
  Future<UploadResult> uploadLatest() async {
    if (_running) return const UploadResult(UploadOutcome.busy);
    final cfg = await _sync.config();
    if (cfg == null) return const UploadResult(UploadOutcome.notConfigured);
    final newest = (await _backups.list()).firstOrNull;
    if (newest == null || newest.name == await _get(_kName)) {
      return UploadResult(UploadOutcome.nothingToSend, name: newest?.name);
    }
    _running = true;
    try {
      final url = SyncService.parseBaseUrl(cfg.url).resolve('/api/backup');
      final expected = await newest.file.length();
      final reply = await _transport.postFile(url, cfg.key, newest.file);
      if (reply.status == 200) {
        final stored = reply.json?['bytes'];
        if (stored != expected) {
          return _fail(
            'The server stored $stored bytes but the backup is $expected. It will be sent again.',
            UploadOutcome.rejected,
          );
        }
        await _set(_kName, newest.name);
        await _set(_kAt, _now().toIso8601String());
        await _set(_kError, null);
        return UploadResult(UploadOutcome.sent, name: newest.name);
      }
      return _fail(switch (reply.status) {
        401 => 'The dashboard did not accept the key.',
        413 => 'The backup is too big for the dashboard server to accept.',
        _ => 'The dashboard had a problem (${reply.status}).',
      }, UploadOutcome.rejected);
    } on SocketException {
      return _fail('No connection to the dashboard.', UploadOutcome.offline);
    } on TimeoutException {
      return _fail(
        'The dashboard did not answer in time.',
        UploadOutcome.offline,
      );
    } on HandshakeException {
      return _fail('The secure connection failed.', UploadOutcome.offline);
    } on FileSystemException {
      return _fail(
        'The backup file could not be read.',
        UploadOutcome.rejected,
      );
    } on SyncException catch (e) {
      return _fail(e.message, UploadOutcome.rejected);
    } finally {
      _running = false;
    }
  }

  Future<UploadResult> _fail(String message, UploadOutcome outcome) async {
    await _set(_kError, message);
    return UploadResult(outcome, message: message);
  }
}
