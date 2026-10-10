import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

import 'tables.dart';

part 'database.g.dart';

/// Thrown when the process is not running on a SQLCipher build of SQLite.
/// Without this check a misconfigured build would silently create a PLAIN,
/// unencrypted database file.
class EncryptionUnavailableException implements Exception {
  @override
  String toString() =>
      'SQLCipher is not available: refusing to open an unencrypted database.';
}

/// Thrown when the key does not open the database file.
class WrongDatabaseKeyException implements Exception {
  @override
  String toString() => 'The database key is wrong, or the file is corrupt.';
}

@DriftDatabase(
  tables: [
    Users,
    Patients,
    Visits,
    Consultations,
    Medicines,
    Batches,
    StockMovements,
    Sales,
    SaleItems,
    Payments,
    ClockEntries,
    Settings,
    SyncOutbox,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// Opens (creating if needed) the encrypted database at [file].
  factory AppDatabase.encrypted(File file, List<int> key) {
    return AppDatabase(
      NativeDatabase(file, setup: (raw) => applyKey(raw, key)),
    );
  }

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  /// Writes an encrypted snapshot of the live database to [path].
  /// The file is encrypted with the same key (SQLCipher VACUUM INTO).
  Future<void> backupTo(String path) async {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
    final escaped = path.replaceAll("'", "''");
    await customStatement("VACUUM INTO '$escaped'");
  }

  /// Current stock of one batch, in base units.
  Future<int> stockOnHand(int batchId) async {
    final row = await customSelect(
      'SELECT COALESCE(SUM(qty_delta), 0) AS q FROM stock_movements '
      'WHERE batch_id = ?',
      variables: [Variable<int>(batchId)],
      readsFrom: {stockMovements},
    ).getSingle();
    return row.read<int>('q');
  }
}

/// Hex key in SQLCipher raw-key syntax, so no passphrase KDF is needed.
String sqlcipherKeyPragma(List<int> key) {
  assert(key.length == 32, 'database key must be 32 bytes');
  final hex = key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return "PRAGMA key = \"x'$hex'\";";
}

/// Applies the key and verifies it. Throws if SQLCipher is missing or the key
/// is wrong. Safe to call from a drift `setup:` callback.
void applyKey(Database raw, List<int> key) {
  final version = raw.select('PRAGMA cipher_version;');
  if (version.isEmpty || '${version.first.values.first}'.isEmpty) {
    raw.close();
    throw EncryptionUnavailableException();
  }
  raw.execute(sqlcipherKeyPragma(key));
  try {
    raw.select('SELECT count(*) FROM sqlite_master;');
  } on SqliteException {
    raw.close();
    throw WrongDatabaseKeyException();
  }
}
