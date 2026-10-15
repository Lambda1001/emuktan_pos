import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../config/app_config.dart';

/// Where a finished receipt goes. Today that is a PDF file; when the thermal
/// printer is chosen, add an ESC/POS implementation and swap the provider.
abstract class ReceiptPrinter {
  /// Prints [text] (from `renderReceipt`). Returns a short description of
  /// where it went, for the cashier ("Saved to ...").
  Future<String> print(String text, {required String name});
}

const double _fontSize = 7;
const double _lineHeight = 8.5;
const double _margin = 2 * PdfPageFormat.mm;

/// The receipt as a PDF on an 80 mm roll: one page, as tall as the text.
/// Uses the same monospaced text the thermal printer will get, so what you
/// see here is the layout the printer will produce.
Future<Uint8List> buildReceiptPdf(String text) async {
  // The built-in Courier font is Latin-1 only; keep anything else printable.
  final safe = text.replaceAll(RegExp(r'[^\x20-\x7E\n]'), '?').trimRight();
  final lines = safe.split('\n').length;
  final format = PdfPageFormat(
    ReceiptConfig.paperWidthMm * PdfPageFormat.mm,
    lines * _lineHeight + 2 * _margin,
    marginAll: _margin,
  );
  final doc = pw.Document();
  doc.addPage(
    pw.Page(
      pageFormat: format,
      build: (_) => pw.Text(
        safe,
        style: pw.TextStyle(
          font: pw.Font.courier(),
          fontSize: _fontSize,
          lineSpacing: _lineHeight - _fontSize,
        ),
      ),
    ),
  );
  return doc.save();
}

/// Saves each receipt as a PDF under Documents/Emuktan/Receipts and opens it.
class PdfReceiptPrinter implements ReceiptPrinter {
  const PdfReceiptPrinter({this.openAfterSave = true, this.directory});
  final bool openAfterSave;

  /// Override for tests; defaults to Documents/Emuktan/Receipts.
  final Directory? directory;

  @override
  Future<String> print(String text, {required String name}) async {
    final dir =
        directory ??
        Directory(
          p.join(
            (await getApplicationDocumentsDirectory()).path,
            'Emuktan',
            'Receipts',
          ),
        );
    await dir.create(recursive: true);
    final safeName = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File(p.join(dir.path, '$safeName.pdf'));
    await file.writeAsBytes(await buildReceiptPdf(text));
    if (openAfterSave && Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', file.path]);
    }
    return 'Saved to ${file.path}';
  }
}
