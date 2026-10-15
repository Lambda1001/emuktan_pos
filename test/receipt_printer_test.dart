import 'dart:convert';
import 'dart:io';

import 'package:emuktan_pos/config/app_config.dart';
import 'package:emuktan_pos/core/receipt_printer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sample = [
    'EMUKTAN'.padLeft(28),
    '-' * ReceiptConfig.charsPerLine,
    'Receipt R20261015-0001',
    'Patient: Zoë Müller', // non-Latin-1 must not break the PDF
    'TOTAL${' ' * 30}KES 180.00',
  ].join('\n');

  test('builds a single-page PDF 80 mm wide', () async {
    final bytes = await buildReceiptPdf(sample);
    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    final pdf = latin1.decode(bytes);
    // 80 mm = 226.77 pt
    expect(pdf, matches(RegExp(r'/MediaBox\s*\[0 0 226\.\d+ ')));
    expect(RegExp(r'/Type\s*/Page\b').allMatches(pdf).length, 1);
  });

  test('PdfReceiptPrinter saves a file named after the receipt', () async {
    final dir = await Directory.systemTemp.createTemp('receipts');
    addTearDown(() => dir.delete(recursive: true));
    final msg = await PdfReceiptPrinter(
      openAfterSave: false,
      directory: dir,
    ).print(sample, name: 'receipt-R20261015/0001');
    final file = File('${dir.path}${Platform.pathSeparator}receipt-R20261015_0001.pdf');
    expect(file.existsSync(), isTrue);
    expect(msg, contains('receipt-R20261015_0001.pdf'));
  });
}
