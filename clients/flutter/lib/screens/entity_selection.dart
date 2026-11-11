import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';

import '../api.dart';
import '../entities.dart';
import '../reports/entity_docs.dart';
import '../widgets/entity_form.dart' show confirm;
import '../widgets/print_panel.dart' show printPdf;
import '../widgets/record_selection.dart';

/// What names a record of a master-data list in messages: its name, else its description, else its code.
String recordName(Map<String, dynamic> r) {
  for (final k in ['name', 'description', 'code']) {
    final v = r[k];
    if (v != null && '$v'.trim().isNotEmpty) return '$v';
  }
  return '#${r['id']}';
}

String _summary(List<Map<String, dynamic>> rows, {int show = 5}) {
  final names = [for (final r in rows.take(show)) recordName(r)];
  return rows.length > show ? '${names.join(', ')} e mais ${rows.length - show}' : names.join(', ');
}

/// One record prints as a portrait sheet, two or more as a landscape list.
PdfPageFormat entityPrintFormat(int count) => count == 1 ? PdfPageFormat.a4 : PdfPageFormat.a4.landscape;

/// Which flag a list can switch for its rows: products are blocked, the rest are active/inactive; null when the rows carry neither.
String? statusFlag(List<Map<String, dynamic>> rows) {
  if (rows.isEmpty) return null;
  if (rows.first.containsKey('blocked')) return 'blocked';
  if (rows.first.containsKey('active')) return 'active';
  return null;
}

bool _isOff(String flag, Map<String, dynamic> r) => flag == 'blocked' ? r['blocked'] == true : r['active'] != true;

/// True when every selected row is already switched "off" (inactive / blocked), so the button offers to switch it back on.
bool selectionIsOff(String flag, List<Map<String, dynamic>> rows) => rows.isNotEmpty && rows.every((r) => _isOff(flag, r));

Future<void> printEntities(BuildContext context, EntitySpec spec, List<Map<String, dynamic>> rows, List<String> filters) async {
  if (rows.isEmpty) return;
  final name = rows.length == 1 ? '${spec.singular} ${recordName(rows.single)}' : '${spec.title} (${rows.length})';
  await printPdf(context, name, () => buildEntityPdf(spec, rows, filters: filters), format: entityPrintFormat(rows.length));
}

Future<void> exportEntityPdf(BuildContext context, EntitySpec spec, List<Map<String, dynamic>> rows, List<String> filters) async {
  if (rows.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final base = (rows.length == 1 ? '${spec.singular}_${recordName(rows.single)}' : spec.title).toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    final saved = await FilePicker.saveFile(
      fileName: '${base.isEmpty ? 'lista' : base}.pdf',
      bytes: await buildEntityPdf(spec, rows, filters: filters),
      mimeType: 'application/pdf',
      dialogTitle: 'Salvar PDF',
    );
    if (saved != null) messenger.showSnackBar(const SnackBar(content: Text('Arquivo salvo')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Falha ao exportar: ${friendlyError(e)}')));
  }
}

Future<void> _failures(BuildContext context, String title, List<String> failed) => showDialog<void>(
  context: context,
  builder: (c) => AlertDialog(
    title: Text(title),
    content: SingleChildScrollView(child: Text(failed.join('\n\n'))),
    actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Fechar'))],
  ),
);

/// Deletes the selected records one by one after a confirmation; the server refuses one that is in use, and that one stays selected.
Future<int> deleteRecords(BuildContext context, ApiClient api, EntitySpec spec, RecordSelection selection) async {
  final rows = selection.rows;
  if (rows.isEmpty) return 0;
  final messenger = ScaffoldMessenger.of(context);
  final ok = await confirm(
    context,
    rows.length == 1
        ? 'Excluir ${recordName(rows.single)}? Isso não pode ser desfeito. Se já estiver em uso em outro cadastro, o sistema recusa.'
        : 'Excluir ${rows.length} registros (${_summary(rows)})? Isso não pode ser desfeito. Os que já estão em uso em outro cadastro não são excluídos.',
    confirmLabel: 'Excluir',
    cancelLabel: 'Voltar',
    danger: true,
  );
  if (!ok) return 0;
  var deleted = 0;
  final failed = <String>[];
  for (final r in rows) {
    try {
      await api.delete('${spec.path}/${r['id']}');
      deleted++;
      selection.set(r, false);
    } catch (e) {
      failed.add('${recordName(r)}: ${friendlyError(e)}');
    }
  }
  if (failed.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(deleted == 1 ? 'Registro excluído' : '$deleted registros excluídos')));
  } else if (context.mounted) {
    await _failures(context, deleted == 0 ? 'Nada foi excluído' : '$deleted excluído${deleted > 1 ? 's' : ''}, ${failed.length} não', failed);
  }
  return deleted;
}

/// Switches the flag of the selected records (inactive/active, or blocked/unblocked for products) with a PUT of the whole row, which the list
/// rows carry. Records already in the wanted state are left alone. Returns how many changed.
Future<int> setFlag(BuildContext context, ApiClient api, EntitySpec spec, RecordSelection selection, {required String flag, required bool off}) async {
  final rows = [
    for (final r in selection.rows)
      if (_isOff(flag, r) != off) r,
  ];
  if (rows.isEmpty) return 0;
  final messenger = ScaffoldMessenger.of(context);
  final verb = off ? 'Inativar' : 'Reativar';
  final ok = await confirm(
    context,
    '$verb ${rows.length == 1 ? recordName(rows.single) : '${rows.length} registros (${_summary(rows)})'}?',
    confirmLabel: verb,
    cancelLabel: 'Voltar',
    danger: off,
  );
  if (!ok) return 0;
  var changed = 0;
  final failed = <String>[];
  for (final r in rows) {
    try {
      await api.put('${spec.path}/${r['id']}', {...r, if (flag == 'blocked') 'blocked': off else 'active': !off});
      changed++;
      selection.set(r, false);
    } catch (e) {
      failed.add('${recordName(r)}: ${friendlyError(e)}');
    }
  }
  if (failed.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(changed == 1 ? '1 registro alterado' : '$changed registros alterados')));
  } else if (context.mounted) {
    await _failures(context, '$changed alterado${changed == 1 ? '' : 's'}, ${failed.length} não', failed);
  }
  return changed;
}

/// Selection bar buttons of a master-data list, laid out as on the customer list: Imprimir and Exportar PDF for everyone, then (with [canWrite])
/// the status switch and Excluir, red and last.
List<Widget> entitySelectionActions(
  BuildContext context,
  ApiClient api,
  EntitySpec spec,
  RecordSelection selection, {
  required List<String> Function() filters,
  required bool canWrite,
  VoidCallback? onChanged,
}) {
  final cs = Theme.of(context).colorScheme;
  final rows = selection.rows;
  final flag = statusFlag(rows);
  final off = flag != null && selectionIsOff(flag, rows);
  void after(Future<int> f) => unawaited(f.then((n) => n > 0 ? onChanged?.call() : null));
  return [
    FilledButton.tonalIcon(
      key: const ValueKey('entity-print'),
      onPressed: () => unawaited(printEntities(context, spec, rows, filters())),
      icon: const Icon(Icons.print_outlined),
      label: const Text('Imprimir'),
    ),
    FilledButton.tonalIcon(
      key: const ValueKey('entity-export'),
      onPressed: () => unawaited(exportEntityPdf(context, spec, rows, filters())),
      icon: const Icon(Icons.picture_as_pdf_outlined),
      label: const Text('Exportar PDF'),
    ),
    if (canWrite) ...[
      if (flag != null)
        OutlinedButton.icon(
          key: const ValueKey('entity-toggle'),
          onPressed: () => after(setFlag(context, api, spec, selection, flag: flag, off: !off)),
          icon: Icon(off ? Icons.check_circle_outline : Icons.block),
          label: Text(off ? 'Ativar' : 'Inativar'),
        ),
      SizedBox(height: 24, child: VerticalDivider(width: 16, color: cs.outline)),
      FilledButton.icon(
        key: const ValueKey('entity-delete'),
        style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
        onPressed: () => after(deleteRecords(context, api, spec, selection)),
        icon: const Icon(Icons.delete_outline),
        label: const Text('Excluir'),
      ),
    ],
  ];
}

/// App bar menu of a record page: print the sheet or save it as a PDF (as on a customer page).
class EntityPdfMenu extends StatelessWidget {
  const EntityPdfMenu({super.key, required this.spec, required this.record});

  final EntitySpec spec;
  final Map<String, dynamic> record;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
    key: const ValueKey('entity-pdf-menu'),
    tooltip: 'Imprimir / Exportar PDF',
    icon: const Icon(Icons.print_outlined),
    onSelected: (v) => unawaited(v == 'print' ? printEntities(context, spec, [record], const []) : exportEntityPdf(context, spec, [record], const [])),
    itemBuilder: (_) => const [
      PopupMenuItem(value: 'print', child: ListTile(leading: Icon(Icons.print_outlined), title: Text('Imprimir ficha'), dense: true)),
      PopupMenuItem(value: 'pdf', child: ListTile(leading: Icon(Icons.picture_as_pdf_outlined), title: Text('Exportar PDF'), dense: true)),
    ],
  );
}
