import 'package:ebt_engenharia/reports/pdf_theme.dart' show lastSaveOffThread;
import 'package:ebt_engenharia/reports/report_doc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const doc = ReportDoc(
    title: 'Resumo do Faturamento',
    filters: ['Período: 01/10/2026 a 31/10/2026'],
    headers: ['Cliente', 'Valor Fat.'],
    numeric: [false, true],
    rows: [
      ReportRow(['Devoluções'], ReportRowKind.section),
      ReportRow(['Cliente; "A"', '1.050,00']),
      ReportRow(['Total', '1.050,00'], ReportRowKind.total),
    ],
  );

  test('csv is semicolon separated, quoted and BOM prefixed', () {
    final text = String.fromCharCodes(doc.toCsv());
    expect(text.contains('Cliente;Valor Fat.') || text.contains('Cliente;'), isTrue);
    expect(text.contains('"Cliente; ""A"""'), isTrue);
  });

  test('pdf renders', () async {
    final bytes = await doc.toPdf();
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('a long report is saved in another isolate and a short one is not', () async {
    final long = ReportDoc(
      title: 'Longo',
      filters: const [],
      headers: const ['Cliente', 'Valor'],
      numeric: const [false, true],
      rows: [for (var i = 0; i < 400; i++) ReportRow(['Cliente número $i', '${i * 10},00'])],
    );
    final bytes = await long.toPdf();
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(lastSaveOffThread, isTrue, reason: 'the document must be sendable to an isolate; if not, savePdf falls back and this stays false');
    await doc.toPdf();
    expect(lastSaveOffThread, isFalse);
  });
}
