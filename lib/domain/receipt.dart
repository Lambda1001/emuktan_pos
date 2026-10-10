import '../config/app_config.dart';
import '../config/brand.dart';
import '../core/format.dart';
import '../data/sales_service.dart';
import '../data/tables.dart';
import 'stock_rules.dart';

/// Plain-text receipt for an 80 mm thermal printer
/// ([ReceiptConfig.charsPerLine] columns). Pure, so it can be tested and
/// later handed to whichever printer driver is chosen.
String renderReceipt(SaleReceipt r, {int width = ReceiptConfig.charsPerLine}) {
  final out = StringBuffer();
  String center(String s) {
    final t = s.length > width ? s.substring(0, width) : s;
    return '${' ' * ((width - t.length) ~/ 2)}$t';
  }

  String pair(String left, String right) {
    if (right.isEmpty) return left;
    final space = width - left.length - right.length;
    if (space >= 1) return '$left${' ' * space}$right';
    return '$left\n${right.padLeft(width)}';
  }

  /// Breaks [s] into lines of at most [width], on spaces where possible.
  List<String> wrap(String s) {
    final lines = <String>[];
    var cur = '';
    for (final word in s.split(' ')) {
      var w = word;
      while (w.length > width) {
        if (cur.isNotEmpty) {
          lines.add(cur);
          cur = '';
        }
        lines.add(w.substring(0, width));
        w = w.substring(width);
      }
      if (cur.isEmpty) {
        cur = w;
      } else if (cur.length + 1 + w.length <= width) {
        cur = '$cur $w';
      } else {
        lines.add(cur);
        cur = w;
      }
    }
    if (cur.isNotEmpty) lines.add(cur);
    return lines;
  }

  final rule = '-' * width;
  out.writeln(center(Brand.name));
  out.writeln(center(Brand.tagline));
  out.writeln(rule);
  out.writeln(pair('Receipt ${r.receiptNo}', ''));
  out.writeln(
    '${formatDate(r.createdAt)}  '
    '${r.createdAt.hour.toString().padLeft(2, '0')}:${r.createdAt.minute.toString().padLeft(2, '0')}',
  );
  out.writeln('Served by ${r.cashierName}');
  out.writeln(rule);

  for (final l in r.lines) {
    wrap(l.name).forEach(out.writeln);
    final unit = modeLabel(l.mode).toLowerCase();
    final what = l.mode == PriceMode.unit
        ? quantityText(l.count, l.baseUnit)
        : '${l.count} $unit${l.count == 1 ? '' : 's'}';
    out.writeln(
      pair(
        '  $what x ${formatKes(l.unitPriceCents, alwaysCents: true)}',
        formatKes(l.totalCents, alwaysCents: true),
      ),
    );
  }

  out.writeln(rule);
  if (r.discountCents > 0) {
    out.writeln(
      pair('Subtotal', formatKes(r.subtotalCents, alwaysCents: true)),
    );
    out.writeln(
      pair('Discount', '-${formatKes(r.discountCents, alwaysCents: true)}'),
    );
  }
  out.writeln(pair('TOTAL', formatKes(r.totalCents, alwaysCents: true)));
  if (r.method == PaymentMethod.cash) {
    out.writeln(
      pair(
        'Cash',
        formatKes(r.tenderedCents ?? r.totalCents, alwaysCents: true),
      ),
    );
    out.writeln(pair('Change', formatKes(r.changeCents, alwaysCents: true)));
  } else {
    out.writeln(pair('Paid by M-Pesa', ''));
    out.writeln('Code ${r.mpesaCode}');
  }
  out.writeln(rule);
  out.writeln(center('Thank you'));
  return out.toString();
}
