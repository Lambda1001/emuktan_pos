# Emuktan POS (Flutter, Windows)

Offline-first dispensary POS. Local data lives in a SQLCipher-encrypted SQLite
file; see `lib/data` (schema) and `lib/core` (key handling).

## Build requirements (Windows)
- Flutter stable, with Windows desktop enabled
- **Visual Studio 2022 with the "Desktop development with C++" workload**
  (needed for `flutter run -d windows` / `flutter build windows`; not needed for tests)

## Commands
    flutter pub get
    dart run build_runner build --delete-conflicting-outputs   # after editing lib/data/tables.dart
    flutter test
    flutter run -d windows

## Encryption design
- SQLCipher build of SQLite is selected in `pubspec.yaml` (`hooks.user_defines.sqlite3.source`).
- `applyKey` refuses to open the database if SQLCipher is not active, so a
  misconfigured build can never silently create a plain database.
- The 256-bit key is random, stored in `db.key` wrapped by Windows DPAPI.
  On first run the owner is shown a recovery key and must record it: without it,
  a reinstall or dead PC makes the database and backups unreadable.
- `AppDatabase.backupTo` uses `VACUUM INTO`, verified by test to be encrypted.

## Conventions
- Money: integer cents. Stock: integer base units (e.g. tablets), as a ledger of
  `stock_movements`; stock on hand is a SUM, never a stored number.
