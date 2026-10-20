import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../config/app_config.dart';
import 'database.dart';
import 'sync_triggers.dart';

/// What the server said.
class SyncReply {
  const SyncReply(this.status, this.json);
  final int status;
  final Map<String, dynamic>? json;
}

/// The network, behind an interface so tests can stand in for the server.
abstract class SyncTransport {
  Future<SyncReply> get(Uri url, String key);
  Future<SyncReply> post(Uri url, String key, Object body);

  /// Sends [file] as the raw request body (`application/octet-stream`),
  /// streamed from disk so a large backup is never held in memory.
  Future<SyncReply> postFile(Uri url, String key, File file);
}

class HttpSyncTransport implements SyncTransport {
  @override
  Future<SyncReply> get(Uri url, String key) => _send('GET', url, key, null);

  @override
  Future<SyncReply> post(Uri url, String key, Object body) =>
      _send('POST', url, key, body);

  @override
  Future<SyncReply> postFile(Uri url, String key, File file) =>
      _send('POST', url, key, null, file: file);

  Future<SyncReply> _send(
    String method,
    Uri url,
    String key,
    Object? body, {
    File? file,
  }) async {
    final client = HttpClient()..connectionTimeout = SyncConfig.requestTimeout;
    // A backup is tens of megabytes over a slow line: allow far longer than a sync.
    final wait = file == null
        ? SyncConfig.requestTimeout
        : SyncConfig.uploadTimeout;
    try {
      final req = await client
          .openUrl(method, url)
          .timeout(SyncConfig.requestTimeout);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
      }
      if (file != null) {
        req.headers.contentType = ContentType.binary;
        req.contentLength = await file.length();
        await req.addStream(file.openRead()).timeout(wait);
      }
      final res = await req.close().timeout(wait);
      final text = await res.transform(utf8.decoder).join().timeout(wait);
      Map<String, dynamic>? json;
      try {
        final d = jsonDecode(text);
        if (d is Map<String, dynamic>) json = d;
      } catch (_) {}
      return SyncReply(res.statusCode, json);
    } finally {
      client.close(force: true);
    }
  }
}

/// A problem with what the owner typed or what the server said, worded for
/// the screen.
class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum SyncOutcome {
  /// Everything queued was accepted (or there was nothing to send).
  ok,

  /// No settings yet.
  notConfigured,

  /// Could not reach the server: normal when the connection is down.
  offline,

  /// The server answered but refused (wrong key, bad row, server error).
  rejected,

  /// A sync was already running.
  busy,
}

class SyncResult {
  const SyncResult(this.outcome, {this.sent = 0, this.message});
  final SyncOutcome outcome;
  final int sent;
  final String? message;
}

class SyncStatus {
  const SyncStatus({
    required this.configured,
    required this.pending,
    this.lastOkAt,
    this.lastError,
  });
  final bool configured;

  /// Changes saved here but not yet accepted by the server.
  final int pending;
  final DateTime? lastOkAt;
  final String? lastError;

  bool isStale(DateTime now) =>
      lastOkAt == null || now.difference(lastOkAt!) > SyncConfig.staleAfter;
}

/// Pushes queued changes to the dashboard. One-way: the clinic is the source
/// of truth and the server only ever receives.
class SyncService {
  SyncService(this._db, {SyncTransport? transport, DateTime Function()? clock})
    : _transport = transport ?? HttpSyncTransport(),
      _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final SyncTransport _transport;
  final DateTime Function() _now;
  bool _running = false;

  static const _kUrl = 'sync.url';
  static const _kKey = 'sync.key';
  static const _kBackfilled = 'sync.backfilled';
  static const _kLastOk = 'sync.lastOkAt';
  static const _kLastError = 'sync.lastError';
  static const _kMpesaStk = 'sync.mpesaStk';

  /// Does the dashboard offer M-Pesa prompts? It says so in every ping and
  /// sync reply; the last answer is remembered so the pay screen needs no
  /// network call to decide whether to show the option.
  Future<bool> mpesaPromptsAvailable() async =>
      await config() != null && await _get(_kMpesaStk) == '1';

  Future<void> _noteFeatures(Map<String, dynamic>? json) async {
    final f = json?['features'];
    if (f is Map) await _set(_kMpesaStk, f['mpesa_stk'] == true ? '1' : '0');
  }

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

  /// The saved server address and key, or null when sync is not set up.
  Future<({String url, String key})?> config() async {
    final url = await _get(_kUrl), key = await _get(_kKey);
    if (url == null || key == null || url.isEmpty || key.isEmpty) return null;
    return (url: url, key: key);
  }

  /// Plain https, or http only for this PC / a developer machine.
  static Uri parseBaseUrl(String text) {
    final t = text.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(t);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      throw SyncException(
        'Enter the dashboard address, like https://example.co.ke',
      );
    }
    final local = uri.host == 'localhost' || uri.host == '127.0.0.1';
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && local)) {
      throw SyncException(
        'The address must start with https:// so the data is protected on the way.',
      );
    }
    return uri;
  }

  /// Saves the address and key. The first time, existing sales and stock are
  /// queued too, so the dashboard starts complete.
  Future<void> configure({required String url, required String key}) async {
    final uri = parseBaseUrl(url);
    final k = key.trim();
    if (k.length < 16) {
      throw SyncException('Paste the full key from the dashboard.');
    }
    await _set(_kUrl, uri.toString());
    await _set(_kKey, k);
    if (await _get(_kBackfilled) == null) {
      await _db.transaction(() async {
        for (final sql in syncBackfillStatements()) {
          await _db.customStatement(sql);
        }
        await _set(_kBackfilled, _now().toIso8601String());
      });
    }
  }

  /// Forgets the server. Queued changes stay queued.
  Future<void> clear() async {
    await _set(_kUrl, null);
    await _set(_kKey, null);
    await _set(_kMpesaStk, null);
  }

  Future<SyncStatus> status() async {
    final pending = await _db
        .customSelect(
          'SELECT COUNT(*) AS n FROM sync_outbox WHERE sent_at IS NULL',
          readsFrom: {_db.syncOutbox},
        )
        .getSingle();
    final ok = await _get(_kLastOk);
    return SyncStatus(
      configured: await config() != null,
      pending: pending.read<int>('n'),
      lastOkAt: ok == null ? null : DateTime.tryParse(ok),
      lastError: await _get(_kLastError),
    );
  }

  /// Checks the address and key without sending anything.
  /// Returns the clinic name the server reports.
  Future<String> testConnection({
    required String url,
    required String key,
  }) async {
    final base = parseBaseUrl(url);
    try {
      final r = await _transport.get(base.resolve('/api/ping'), key.trim());
      if (r.status == 401) {
        throw SyncException('The dashboard did not accept this key.');
      }
      if (r.status != 200) {
        throw SyncException(
          'The dashboard answered with an error (${r.status}).',
        );
      }
      await _noteFeatures(r.json);
      return (r.json?['clinic'] as String?) ?? 'connected';
    } on SocketException {
      throw SyncException(
        'Could not reach the dashboard. Check the internet and the address.',
      );
    } on TimeoutException {
      throw SyncException('The dashboard did not answer in time.');
    } on HandshakeException {
      throw SyncException('The secure connection failed. Check the address.');
    }
  }

  /// Pushes everything queued, in batches, oldest first. Never throws:
  /// problems are returned and recorded for the status bar. Also sent when
  /// nothing is queued, so the server knows this PC is alive.
  Future<SyncResult> syncNow() async {
    if (_running) return const SyncResult(SyncOutcome.busy);
    final cfg = await config();
    if (cfg == null) return const SyncResult(SyncOutcome.notConfigured);
    _running = true;
    try {
      final url = parseBaseUrl(cfg.url).resolve('/api/sync');
      var sent = 0;
      while (true) {
        final rows =
            await (_db.select(_db.syncOutbox)
                  ..where((r) => r.sentAt.isNull())
                  ..orderBy([(r) => OrderingTerm.asc(r.id)])
                  ..limit(SyncConfig.batchSize))
                .get();
        final reply = await _transport.post(url, cfg.key, {
          'app_version': SyncConfig.appVersion,
          'rows': [
            for (final r in rows)
              {
                'entity': r.entity,
                'local_id': r.entityId,
                'data': jsonDecode(r.payloadJson),
              },
          ],
        });
        if (reply.status != 200) {
          return await _fail(
            reply.status == 401
                ? 'The dashboard did not accept the key.'
                : reply.status == 422
                ? 'The dashboard refused some data: ${reply.json?['error'] ?? 'unknown'}'
                : 'The dashboard had a problem (${reply.status}).',
            SyncOutcome.rejected,
          );
        }
        await _noteFeatures(reply.json);
        if (rows.isNotEmpty) {
          await (_db.update(_db.syncOutbox)
                ..where((r) => r.id.isIn(rows.map((r) => r.id).toList())))
              .write(SyncOutboxCompanion(sentAt: Value(_now())));
          sent += rows.length;
        }
        if (rows.length < SyncConfig.batchSize) break;
      }
      await _set(_kLastOk, _now().toIso8601String());
      await _set(_kLastError, null);
      await _prune();
      return SyncResult(SyncOutcome.ok, sent: sent);
    } on SocketException {
      return _fail('No connection to the dashboard.', SyncOutcome.offline);
    } on TimeoutException {
      return _fail(
        'The dashboard did not answer in time.',
        SyncOutcome.offline,
      );
    } on HandshakeException {
      return _fail('The secure connection failed.', SyncOutcome.offline);
    } finally {
      _running = false;
    }
  }

  Future<SyncResult> _fail(String message, SyncOutcome outcome) async {
    await _set(_kLastError, message);
    return SyncResult(outcome, message: message);
  }

  Future<void> _prune() async {
    final cutoff = _now().subtract(SyncConfig.keepSent);
    await (_db.delete(_db.syncOutbox)..where(
          (r) => r.sentAt.isNotNull() & r.sentAt.isSmallerThanValue(cutoff),
        ))
        .go();
  }
}
