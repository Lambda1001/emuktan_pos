import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:sqlite3/sqlite3.dart';

import 'tables.dart';
import 'sync_triggers.dart';

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
    Settings,
    SyncOutbox,
    SaleReturns,
    HeldSales,
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

  /// The newest schema this build understands. A backup made by a newer
  /// build is refused on restore rather than opened wrongly.
  static const currentSchemaVersion = 5;

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createSyncTriggers();
    },
    onUpgrade: (m, from, to) async {
      // v2: returns after a sale.
      if (from < 2) await m.createTable(saleReturns);
      // v3: sales set aside before payment.
      if (from < 3) await m.createTable(heldSales);
      // v4: the time clock was dropped from the product.
      if (from < 4) await customStatement('DROP TABLE IF EXISTS clock_entries');
      // v5: changes to sales and stock are queued for the dashboard.
      if (from < 5) await _createSyncTriggers();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );

  Future<void> _createSyncTriggers() async {
    for (final sql in syncTriggerStatements()) {
      await customStatement(sql);
    }
  }

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
