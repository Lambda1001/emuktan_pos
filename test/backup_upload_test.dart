import 'dart:io';
import 'dart:typed_data';

import 'package:emuktan_pos/data/backup_service.dart';
import 'package:emuktan_pos/data/backup_upload.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/sync_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _key(int seed) =>
    Uint8List.fromList(List.generate(32, (i) => (i * 7 + seed) & 0xff));

/// Stands in for the server: keeps what was uploaded.
class FakeBackupServer implements SyncTransport {
  final uploads = <({Uri url, String key, Uint8List bytes})>[];
  int status = 200;
  int? bytesReported; // overrides the byte count in the reply
  Object? throwOnSend;

  @override
  Future<SyncReply> postFile(Uri url, String key, File file) async {
    if (throwOnSend != null) throw throwOnSend!;
    final bytes = await file.readAsBytes();
    uploads.add((url: url, key: key, bytes: bytes));
    return SyncReply(status, {
      'stored': 'x.db',
      'bytes': bytesReported ?? bytes.length,
    });
  }

  @override
  Future<SyncReply> get(Uri url, String key) async => SyncReply(200, {});

  @override
  Future<SyncReply> post(Uri url, String key, Object body) async =>
      SyncReply(200, {'accepted': 0});
}

void main() {
  late Directory root, data;
  late AppDatabase db;
  late BackupService backups;
  late SyncService sync;
  late FakeBackupServer server;
  late BackupUploader up;
  var now = DateTime(2026, 10, 20, 9, 0, 0);
  final key = _key(1);
  const url = 'https://dash.example.co.ke';
  const apiKey = 'good-key-good-key-1';

  setUp(() async {
    now = DateTime(2026, 10, 20, 9, 0, 0);
    root = Directory.systemTemp.createTempSync('emuktan_upload_');
    data = Directory(p.join(root.path, 'data'))..createSync();
    db = AppDatabase.encrypted(File(p.join(data.path, 'emuktan.db')), key);
    await db
        .into(db.users)
        .insert(
          UsersCompanion.insert(
            username: 'secretname',
            displayName: 'Wanjiru Kamau',
            role: Role.owner,
            secretHash: 'h',
            secretSalt: 's',
          ),
        );
    backups = BackupService(db, data, key, clock: () => now);
    await backups.setFolder(p.join(root.path, 'usb'));
    server = FakeBackupServer();
    sync = SyncService(db, transport: server, clock: () => now);
    up = BackupUploader(db, backups, sync, transport: server, clock: () => now);
  });
  tearDown(() async {
    await db.close();
    root.deleteSync(recursive: true);
  });

  Future<void> configure() => sync.configure(url: url, key: apiKey);

  test('does nothing until the dashboard is set up', () async {
    await backups.backupNow();
    final r = await up.uploadLatest();
    expect(r.outcome, UploadOutcome.notConfigured);
    expect(server.uploads, isEmpty);
  });

  test('does nothing when there is no backup yet', () async {
    await configure();
    expect((await up.uploadLatest()).outcome, UploadOutcome.nothingToSend);
    expect(server.uploads, isEmpty);
  });

  test('sends the newest backup once, to /api/backup, with the key', () async {
    await configure();
    final b = await backups.backupNow();
    final r = await up.uploadLatest();
    expect(r.outcome, UploadOutcome.sent);
    expect(r.name, b.name);
    expect(server.uploads, hasLength(1));
    expect(server.uploads.single.url.toString(), '$url/api/backup');
    expect(server.uploads.single.key, apiKey);
    expect(server.uploads.single.bytes, await b.file.readAsBytes());

    final s = await up.status();
    expect(s.name, b.name);
    expect(s.sentAt, now);
    expect(s.error, isNull);
    expect(await up.hasUnsent(), isFalse);

    // Asked again: it is already there, so nothing is sent.
    expect((await up.uploadLatest()).outcome, UploadOutcome.nothingToSend);
    expect(server.uploads, hasLength(1));
  });

  test('what leaves the PC is encrypted, never the readable data', () async {
    await configure();
    await backups.backupNow();
    await up.uploadLatest();
    final sent = server.uploads.single.bytes;
    final text = String.fromCharCodes(sent);
    expect(text.startsWith('SQLite format 3'), isFalse);
    expect(text.contains('Wanjiru'), isFalse);
    expect(text.contains('secretname'), isFalse);
    // Yet it is a sound backup that the clinic key opens.
    final copy = File(p.join(root.path, 'received.db'))..writeAsBytesSync(sent);
    expect(verifyBackupFile(copy, key).userCount, 1);
  });

  test('a newer backup is sent in its turn', () async {
    await configure();
    await backups.backupNow();
    await up.uploadLatest();
    now = now.add(const Duration(days: 1));
    final second = await backups.backupNow();
    expect(await up.hasUnsent(), isTrue);
    final r = await up.uploadLatest();
    expect(r.outcome, UploadOutcome.sent);
    expect(r.name, second.name);
    expect(server.uploads, hasLength(2));
  });

  test('offline is recorded, quiet, and retried to success', () async {
    await configure();
    final b = await backups.backupNow();
    server.throwOnSend = const SocketException('no route');
    final r = await up.uploadLatest();
    expect(r.outcome, UploadOutcome.offline);
    expect((await up.status()).error, contains('No connection'));
    expect((await up.status()).name, isNull);
    expect(await up.hasUnsent(), isTrue);

    server.throwOnSend = null;
    now = now.add(const Duration(minutes: 30));
    expect((await up.uploadLatest()).outcome, UploadOutcome.sent);
    final s = await up.status();
    expect(s.error, isNull);
    expect(s.name, b.name);
  });

  test('refusals are explained in plain words and not marked sent', () async {
    await configure();
    await backups.backupNow();
    for (final c in [
      (401, 'did not accept the key'),
      (413, 'too big'),
      (500, 'problem (500)'),
    ]) {
      server.status = c.$1;
      final r = await up.uploadLatest();
      expect(r.outcome, UploadOutcome.rejected, reason: '${c.$1}');
      expect(r.message, contains(c.$2));
      expect(await up.hasUnsent(), isTrue);
    }
  });

  test(
    'a server that stored the wrong number of bytes is not trusted',
    () async {
      await configure();
      await backups.backupNow();
      server.bytesReported = 10;
      final r = await up.uploadLatest();
      expect(r.outcome, UploadOutcome.rejected);
      expect(r.message, contains('stored 10 bytes'));
      expect(await up.hasUnsent(), isTrue);
    },
  );

  test('a failure to read the file does not crash', () async {
    await configure();
    final b = await backups.backupNow();
    b.file.deleteSync();
    // The folder no longer lists it, so there is simply nothing to send.
    expect((await up.uploadLatest()).outcome, UploadOutcome.nothingToSend);
  });
}
