/// Shop-level settings that are decisions, not code. Edit here.
abstract final class AppConfig {
  static const String currency = 'KES';

  /// Lock the screen (back to sign-in) after this long without input.
  static const Duration inactivityLock = Duration(minutes: 5);

  /// PIN length allowed for staff.
  static const int pinMinLength = 4;
  static const int pinMaxLength = 6;

  /// Failed PIN attempts before a short pause, and how long the pause is.
  static const int pinMaxAttempts = 5;
  static const Duration pinLockout = Duration(seconds: 30);
}

/// Receipt printer. 80 mm thermal paper (decided Oct 2026).
abstract final class ReceiptConfig {
  static const int paperWidthMm = 80;

  /// Printable characters per line in the printer's standard font (Font A,
  /// 48 columns on a typical 80 mm printer). Confirm when the printer is chosen.
  static const int charsPerLine = 48;
}

/// Stock rules.
abstract final class StockConfig {
  /// A batch expiring within this many days is flagged "Expires soon".
  static const int expiringSoonDays = 90;
}

/// Backups.
abstract final class BackupConfig {
  /// A new automatic backup is taken when the last one is older than this.
  static const Duration every = Duration(hours: 24);

  /// How often the running app checks whether a backup is due.
  static const Duration checkEvery = Duration(minutes: 30);

  /// Backups kept in the folder; older ones are removed after a new one.
  static const int keep = 14;

  /// The status bar turns amber when the last backup is older than this.
  static const Duration staleAfter = Duration(hours: 48);
}

/// Sync to the web dashboard (docs/dashboard/sync-protocol.md).
abstract final class SyncConfig {
  /// Sent with every push so the server knows which build is installed.
  static const String appVersion = '1.0.0';

  /// How often the running app tries to push while it is open.
  static const Duration every = Duration(minutes: 5);

  /// Rows per request. The server refuses more than this.
  static const int batchSize = 500;

  /// The status bar turns amber when nothing has got through for this long.
  static const Duration staleAfter = Duration(hours: 24);

  /// Sent rows are kept this long, then deleted from the outbox.
  static const Duration keepSent = Duration(days: 30);

  /// Give up on a request after this long (the clinic's connection is slow).
  static const Duration requestTimeout = Duration(seconds: 20);

  /// Give up on sending a backup file after this long.
  static const Duration uploadTimeout = Duration(minutes: 10);
}
