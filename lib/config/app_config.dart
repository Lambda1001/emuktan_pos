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
