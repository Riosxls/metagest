import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../entities.dart';
import 'pdf_theme.dart';

/// Value of one form field of a record as printed: choices by their label, booleans as Sim/Não, dates as dd/mm/aaaa, lookups by the name the
/// row carries next to the id (`classId` -> `className`) and left out when it has none.
String entityFieldValue(FieldSpec f, Map<String, dynamic> row) {
  final v = row[f.key];
  if (v == null || '$v'.isEmpty) return '';
  switch (f.type) {
    case FieldType.choice:
      return f.choices['$v'] ?? fmt(v);
    case FieldType.lookup:
      final base = f.key.endsWith('Id') ? f.key.substring(0, f.key.length - 2) : f.key;
      final name = row['${base}Name'] ?? row['${base}Description'] ?? row['${base}Code'];
      return name == null ? '' : '$name';
    case FieldType.date:
      return fmtDay(v);
    default:
      return fmt(v);
  }
}

pw.TextStyle _b(double size) => pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: size);
pw.TextStyle _n(double size) => pw.TextStyle(fontSize: size);

String _title(Map<String, dynamic> r) {
  final code = '${r['code'] ?? ''}'.trim();
  final name = '${r['name'] ?? r['description'] ?? ''}'.trim();
  return [code, name].where((e) => e.isNotEmpty).join(' · ');
}

/// One record on one portrait A4 page: every field of the registration form, labelled, under the record's code and name.
Future<Uint8List> buildEntitySheetPdf(EntitySpec spec, Map<String, dynamic> row) async {
  final doc = pw.Document(title: '${spec.singular} ${_title(row)}', theme: await pdfTheme());
  final fields = [for (final f in spec.fields) (f.label, entityFieldValue(f, row))];
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      footer: (c) => pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Página ${c.pageNumber}/${c.pagesCount}', style: _n(7))),
      build: (_) => [
        pw.Text(spec.singular, style: _n(10)),
        pw.Text(_title(row), style: _b(15)),
        pw.Divider(thickness: 1),
        pw.SizedBox(height: 4),
        pw.Table(
          columnWidths: const {0: pw.FlexColumnWidth(2), 1: pw.FlexColumnWidth(5)},
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.3), bottom: pw.BorderSide(color: PdfColors.grey600, width: 0.5)),
          children: [
            for (final (label, value) in fields)
              pw.TableRow(
                children: [
                  pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 3), child: pw.Text(label, style: _b(9))),
                  pw.Padding(padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 3), child: pw.Text(value.isEmpty ? '—' : value, style: _n(9))),
                ],
              ),
          ],
        ),
      ],
    ),
  );
  return savePdf(doc);
}

/// Several records as a landscape spreadsheet: the columns of the list, the header row repeated on every page, page numbers and the total.
Future<Uint8List> buildEntityListPdf(EntitySpec spec, List<Map<String, dynamic>> rows, {List<String> filters = const []}) async {
  final doc = pw.Document(title: spec.title, theme: await pdfTheme());
  final count = '${rows.length} ${rows.length == 1 ? 'registro' : 'registros'}';
  final now = DateTime.now();
  final stamp = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
  pw.Widget cell(String t, {bool bold = false, bool right = false}) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
    child: pw.Text(t, style: bold ? _b(8) : _n(8), textAlign: right ? pw.TextAlign.right : pw.TextAlign.left),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(spec.title, style: _b(13)),
          if (filters.isNotEmpty) pw.Text(filters.join('   |   '), style: _n(8)),
          pw.Divider(thickness: 0.8, height: 8),
        ],
      ),
      footer: (c) => pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [pw.Text('$count · emitido em $stamp', style: _n(7)), pw.Text('Página ${c.pageNumber}/${c.pagesCount}', style: _n(7))],
      ),
      build: (_) => [
        pw.Table(
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.3), bottom: pw.BorderSide(color: PdfColors.grey600, width: 0.5)),
          children: [
            pw.TableRow(
              repeat: true,
              decoration: const pw.BoxDecoration(color: PdfColors.grey300),
              children: [for (final c in spec.columns) cell(c.label, bold: true, right: c.numeric)],
            ),
            for (final r in rows)
              pw.TableRow(children: [for (final c in spec.columns) cell(c.value(r), right: c.numeric)]),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Text('Total: $count', style: _b(9)),
      ],
    ),
  );
  return savePdf(doc, offThread: rows.length > 150);
}

/// What printing a selection does, as for customers: one record gets its sheet (portrait), two or more get the list (landscape).
Future<Uint8List> buildEntityPdf(EntitySpec spec, List<Map<String, dynamic>> rows, {List<String> filters = const []}) =>
    rows.length == 1 ? buildEntitySheetPdf(spec, rows.single) : buildEntityListPdf(spec, rows, filters: filters);
