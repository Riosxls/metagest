import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../widgets/entity_form.dart' show confirm;
import '../widgets/record_selection.dart';

/// Names of the customers in the confirmation: the first few, then "e mais N".
String customerDeleteSummary(List<Map<String, dynamic>> rows, {int show = 5}) {
  final names = [for (final r in rows.take(show)) '${r['name']}'];
  return rows.length > show ? '${names.join(', ')} e mais ${rows.length - show}' : names.join(', ');
}

/// Deletes the selected customers one by one after a confirmation. The server refuses a customer that is still in use (orders, quotes,
/// linked products); those stay, are named in the result, and remain selected. Returns how many were deleted.
Future<int> deleteCustomers(BuildContext context, ApiClient api, RecordSelection selection) async {
  final rows = selection.rows;
  if (rows.isEmpty) return 0;
  final messenger = ScaffoldMessenger.of(context);
  final one = rows.length == 1;
  final ok = await confirm(
    context,
    one
        ? 'Excluir o cliente ${rows.single['name']}? Isso não pode ser desfeito. Se ele já tem pedidos ou orçamentos, use Inativar.'
        : 'Excluir ${rows.length} clientes (${customerDeleteSummary(rows)})? Isso não pode ser desfeito. Clientes que já têm pedidos, orçamentos ou produtos não são excluídos; para esses use Inativar.',
    confirmLabel: 'Excluir',
    cancelLabel: 'Voltar',
    danger: true,
  );
  if (!ok) return 0;
  var deleted = 0;
  final failed = <String>[];
  for (final r in rows) {
    try {
      await api.delete('/api/customers/${r['id']}');
      deleted++;
      selection.set(r, false);
    } catch (e) {
      failed.add('${r['name']}: ${friendlyError(e)}');
    }
  }
  if (failed.isEmpty) {
    messenger.showSnackBar(SnackBar(content: Text(deleted == 1 ? 'Cliente excluído' : '$deleted clientes excluídos')));
  } else if (context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(deleted == 0 ? 'Nenhum cliente excluído' : '$deleted excluído${deleted > 1 ? 's' : ''}, ${failed.length} não'),
        content: SingleChildScrollView(child: Text(failed.join('\n\n'))),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Fechar'))],
      ),
    );
  }
  return deleted;
}
