import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import 'attention.dart';
import 'pipeline.dart';

/// Customers whose register keeps an NF from being issued (no IBGE code, CEP, IE...), as the server finds them with the same checks the emission makes.
/// Each entry: `customerId`, `name`, `openOrders` and `addresses` (`label`, `gaps`). A failure answers an empty list: this is a hint, never a reason to hide a screen.
Future<List<Map<String, dynamic>>> fetchFiscalProblems(ApiClient api, {int? customerId}) async {
  try {
    final r = await api.get('/api/fiscal/customer-problems', customerId == null ? null : {'customerId': customerId});
    return r is List ? r.cast<Map<String, dynamic>>() : const [];
  } catch (e) {
    debugPrint('fiscal problems: not loaded: $e');
    return const [];
  }
}

/// What a customer lacks, one line per address: "Rua X · Cidade: código IBGE do município, CEP".
List<String> fiscalProblemLines(Map<String, dynamic> p) => [
  for (final a in (p['addresses'] as List).cast<Map<String, dynamic>>()) '${a['label']}: ${(a['gaps'] as List).join(', ')}',
];

/// A small exclamation next to a customer: the register still lacks something the NF needs. The tooltip says what.
class FiscalProblemBadge extends StatelessWidget {
  const FiscalProblemBadge({super.key, required this.problem});

  final Map<String, dynamic> problem;

  @override
  Widget build(BuildContext context) {
    final (_, fg) = toneColors(context, Tone.warning);
    return Tooltip(
      message: 'Cadastro incompleto para emitir NF:\n${fiscalProblemLines(problem).join('\n')}',
      child: Icon(Icons.error_outline, key: ValueKey('fiscal-problem-${problem['customerId']}'), size: 16, color: fg),
    );
  }
}

/// "26 clientes com cadastro incompleto para emitir NF · 3 com pedido em aberto".
String fiscalProblemsText(List<Map<String, dynamic>> problems) {
  final withOrders = problems.where((p) => ((p['openOrders'] as num?) ?? 0) > 0).length;
  return '${problems.length} ${problems.length == 1 ? 'cliente com cadastro incompleto' : 'clientes com cadastro incompleto'} para emitir NF'
      '${withOrders > 0 ? ' · $withOrders com pedido em aberto' : ''}';
}

/// Strip over the customer list with an X to dismiss it; the way to the list is the attention button of the toolbar ([fiscalProblemsNotice]).
class FiscalProblemsAlert extends StatelessWidget {
  const FiscalProblemsAlert({super.key, required this.problems});

  final List<Map<String, dynamic>> problems;

  @override
  Widget build(BuildContext context) => NoticeStrip(
    stripKey: const ValueKey('fiscal-problems-alert'),
    id: 'customers-fiscal',
    count: problems.length,
    icon: Icons.error_outline,
    text: fiscalProblemsText(problems),
  );
}

/// The notice that opens the list of customers that cannot be invoiced yet.
AttentionNotice fiscalProblemsNotice(BuildContext context, List<Map<String, dynamic>> problems, void Function(int customerId) onOpen) =>
    AttentionNotice(Icons.error_outline, fiscalProblemsText(problems), () => unawaited(showFiscalProblemsDialog(context, problems, onOpen)));

/// The customers that cannot be invoiced yet, those with open orders first, each with what its address lacks.
Future<void> showFiscalProblemsDialog(BuildContext context, List<Map<String, dynamic>> problems, void Function(int customerId) onOpen) {
  final sorted = [...problems]..sort((a, b) => ((b['openOrders'] as num?) ?? 0).compareTo((a['openOrders'] as num?) ?? 0));
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Cadastros incompletos para a NF (${problems.length})'),
      content: SizedBox(
        width: 560,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in sorted)
              ListTile(
                key: ValueKey('fiscal-problem-row-${p['customerId']}'),
                dense: true,
                title: Text('${p['name']}${((p['openOrders'] as num?) ?? 0) > 0 ? ' · ${p['openOrders']} pedido(s) em aberto' : ''}', overflow: TextOverflow.ellipsis),
                subtitle: Text(fiscalProblemLines(p).join('\n')),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(ctx);
                  onOpen(p['customerId'] as int);
                },
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Fechar'))],
    ),
  );
}

/// On the customer page: what this customer's addresses still lack to be the recipient of an NF, and where to fix it.
class FiscalProblemBanner extends StatelessWidget {
  const FiscalProblemBanner({super.key, required this.problem});

  final Map<String, dynamic>? problem;

  @override
  Widget build(BuildContext context) {
    final p = problem;
    if (p == null) return const SizedBox.shrink();
    final (bg, fg) = toneColors(context, Tone.warning);
    return Padding(
      key: const ValueKey('fiscal-problem-banner'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, size: 18, color: fg),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cadastro incompleto para emitir NF', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: fg, fontWeight: FontWeight.w600)),
                    for (final line in fiscalProblemLines(p)) Text(line, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
                    Text('Onde resolver: aba Locais de entrega.', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: fg)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
