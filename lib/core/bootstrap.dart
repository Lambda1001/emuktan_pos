import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/database.dart';
import 'key_store.dart';

class AppContext {
  AppContext({
    required this.db,
    required this.dataDir,
    required this.newRecoveryKey,
  });

  final AppDatabase db;
  final Directory dataDir;

  /// Non-null only on the very first run: the owner must record it.
  final String? newRecoveryKey;
}

/// Opens the encrypted database, creating the key on first run.
Future<AppContext> bootstrap({Directory? dataDir, KeyStore? keyStore}) async {
  final dir =
      dataDir ??
      Directory(
        p.join((await getApplicationSupportDirectory()).path, 'Emuktan'),
      );
  await dir.create(recursive: true);
  final store = keyStore ?? DpapiKeyStore(File(p.join(dir.path, 'db.key')));
  final loaded = await store.loadOrCreate();
  final Uint8List key = loaded.key;
  final db = AppDatabase.encrypted(File(p.join(dir.path, 'emuktan.db')), key);
  // Force the connection open now so a wrong key or missing SQLCipher fails
  // here, with a clear error, instead of on the first screen.
  await db.customSelect('SELECT 1').get();
  return AppContext(
    db: db,
    dataDir: dir,
    newRecoveryKey: loaded.created ? formatRecoveryKey(key) : null,
  );
}
