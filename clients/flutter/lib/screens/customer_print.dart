import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';

import '../api.dart';
import '../reports/print_docs.dart' show buildCustomersPdf;
import '../widgets/print_panel.dart' show printPdf;
import '../widgets/record_selection.dart';
import 'customer_delete.dart';

/// Lines under the title of the customer list PDF: what narrowed the list (search text, situation).
List<String> customerPrintFilters({String search = '', String? active}) => [
  if (search.trim().isNotEmpty) 'Busca: ${search.trim()}',
  if (active == 'true') 'Situação: ativos' else if (active == 'false') 'Situação: inativos',
];

/// One customer prints as a portrait sheet, two or more as a landscape list.
PdfPageFormat customerPrintFormat(int count) => count == 1 ? PdfPageFormat.a4 : PdfPageFormat.a4.landscape;

String _fileName(List<Map<String, dynamic>> rows) {
  if (rows.length != 1) return 'clientes.pdf';
  final base = '${rows.single['name'] ?? 'cliente'}'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
  return 'ficha_cliente_${base.isEmpty ? 'cliente' : base}.pdf';
}

String _jobName(List<Map<String, dynamic>> rows) => rows.length == 1 ? 'Ficha do cliente ${rows.single['name']}' : 'Lista de clientes (${rows.length})';

Future<void> printCustomers(BuildContext context, ApiClient api, List<Map<String, dynamic>> rows, {List<String> filters = const []}) async {
  if (rows.isEmpty) return;
  await printPdf(context, _jobName(rows), () => buildCustomersPdf(api, rows, filters: filters), format: customerPrintFormat(rows.length));
}

Future<void> exportCustomersPdf(BuildContext context, ApiClient api, List<Map<String, dynamic>> rows, {List<String> filters = const []}) async {
  if (rows.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = await buildCustomersPdf(api, rows, filters: filters);
    final saved = await FilePicker.saveFile(fileName: _fileName(rows), bytes: bytes, mimeType: 'application/pdf', dialogTitle: 'Salvar PDF');
    if (saved != null) messenger.showSnackBar(const SnackBar(content: Text('Arquivo salvo')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Falha ao exportar: ${friendlyError(e)}')));
  }
}

/// Imprimir / Exportar PDF buttons of the customer list's selection bar, plus Excluir for those who may edit customers ([onDeleted] reloads the list).
List<Widget> customerSelectionActions(
  BuildContext context,
  ApiClient api,
  RecordSelection selection, {
  required List<String> Function() filters,
  bool canDelete = false,
  VoidCallback? onDeleted,
}) => [
  OutlinedButton.icon(
    key: const ValueKey('customers-print'),
    onPressed: () => unawaited(printCustomers(context, api, selection.rows, filters: filters())),
    icon: const Icon(Icons.print_outlined),
    label: const Text('Imprimir'),
  ),
  OutlinedButton.icon(
    key: const ValueKey('customers-export'),
    onPressed: () => unawaited(exportCustomersPdf(context, api, selection.rows, filters: filters())),
    icon: const Icon(Icons.picture_as_pdf_outlined),
    label: const Text('Exportar PDF'),
  ),
  if (canDelete)
    OutlinedButton.icon(
      key: const ValueKey('customers-delete'),
      onPressed: () => unawaited(deleteCustomers(context, api, selection).then((n) => n > 0 ? onDeleted?.call() : null)),
      icon: const Icon(Icons.delete_outline),
      label: const Text('Excluir'),
    ),
];

/// App bar menu of a customer page: print the sheet or save it as a PDF.
class CustomerPdfMenu extends StatelessWidget {
  const CustomerPdfMenu({super.key, required this.api, required this.customer});

  final ApiClient api;
  final Map<String, dynamic> customer;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('customer-pdf-menu'),
    tooltip: 'Imprimir / Exportar PDF',
    icon: const Icon(Icons.print_outlined),
    onSelected: (v) => unawaited(v == 'print' ? printCustomers(context, api, [customer]) : exportCustomersPdf(context, api, [customer])),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: 'print',
        child: ListTile(leading: Icon(Icons.print_outlined), title: Text('Imprimir ficha'), dense: true),
      ),
      PopupMenuItem(
        value: 'pdf',
        child: ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('Exportar PDF'), dense: true),
      ),
    ],
  );
}
