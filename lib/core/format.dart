import '../config/app_config.dart';

/// Display and parsing helpers. Money is integer cents (DESIGN.md section 9).

String _group(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// "KES 1,320" - cents only when non-zero, or always on receipts.
String formatKes(int cents, {bool alwaysCents = false}) {
  final abs = cents.abs();
  final frac = abs % 100;
  final showFrac = alwaysCents || frac != 0;
  final body =
      '${_group(abs ~/ 100)}${showFrac ? '.${frac.toString().padLeft(2, '0')}' : ''}';
  return '${cents < 0 ? '-' : ''}${AppConfig.currency} $body';
}

/// Parses what a person types into a money field ("1,320", "12.5", "0.35").
/// Returns cents, or null when it is not a valid amount.
int? parseKes(String input) {
  final s = input.trim().replaceAll(',', '');
  final m = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(s);
  if (m == null) return null;
  final whole = int.parse(m.group(1)!);
  final frac = int.parse((m.group(2) ?? '0').padRight(2, '0'));
  return whole * 100 + frac;
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "07 Oct 2026"
String formatDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')} ${_months[d.month - 1]} ${d.year}';

/// "Dec 2026"
String formatExpiry(DateTime d) => '${_months[d.month - 1]} ${d.year}';

/// "842 tablets", "1 tablet", "250 ml". Unit names are shop-entered, so the
/// plural is a simple rule: short names (ml, mg, g) and names already ending
/// in "s" are left alone.
String quantityText(int n, String unit) {
  final u = unit.trim();
  if (n == 1 || u.length <= 2 || u.endsWith('s')) return '${_group(n)} $u';
  final plural = RegExp(r'(x|ch|sh)$').hasMatch(u) ? '${u}es' : '${u}s';
  return '${_group(n)} $plural';
}

/// Parses "MM/YYYY" or "M/YY" into the LAST day of that month, which is the
/// date a batch stays usable until. Null if invalid.
DateTime? parseExpiry(String input) {
  final m = RegExp(
    r'^\s*(\d{1,2})\s*[/\-]\s*(\d{2}|\d{4})\s*$',
  ).firstMatch(input);
  if (m == null) return null;
  final month = int.parse(m.group(1)!);
  var year = int.parse(m.group(2)!);
  if (year < 100) year += 2000;
  if (month < 1 || month > 12 || year < 2000 || year > 2100) return null;
  return DateTime(year, month + 1, 0);
}

/// "14:32" (24 hour, DESIGN.md section 9).
String formatTime(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Parses "DD/MM/YYYY" (or "D/M/YYYY") into a date. Null if it is not a real
/// calendar date.
DateTime? parseDate(String input) {
  final m = RegExp(
    r'^\s*(\d{1,2})\s*[/\-.]\s*(\d{1,2})\s*[/\-.]\s*(\d{4})\s*$',
  ).firstMatch(input);
  if (m == null) return null;
  final day = int.parse(m.group(1)!);
  final month = int.parse(m.group(2)!);
  final year = int.parse(m.group(3)!);
  if (year < 1900 || month < 1 || month > 12 || day < 1) return null;
  final d = DateTime(year, month, day);
  return d.month == month && d.day == day ? d : null;
}

/// "07/10/1990", the form [parseDate] reads back.
String formatDateInput(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
