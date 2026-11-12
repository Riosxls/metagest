import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../entities.dart';
import '../session.dart';
import '../widgets/entity_form.dart' show confirm;
import '../widgets/load_error.dart';
import '../widgets/pipeline.dart';
import '../widgets/record_list.dart';
import '../widgets/record_skeleton.dart';
import 'sales_common.dart';

/// The "Nota Fiscal" step of an order: the preview of the NF the load would get (same CFOP, price, tax and duplicata rules as the real emission), the checklist of
/// what is still missing in the registers, and the button that confirms it. The commercial team issues the NF when the truck waits to load, with the weighed
/// quantities, so "Confirmar e emitir NF" creates the delivery, ships it (stock out) and emits the NF in one act; then the Certificado step follows.
class OrderInvoiceScreen extends StatefulWidget {
  const OrderInvoiceScreen({super.key, required this.session, required this.id});

  final Session session;
  final int id;

  @override
  State<OrderInvoiceScreen> createState() => _OrderInvoiceScreenState();
}

class _OrderInvoiceScreenState extends State<OrderInvoiceScreen> {
  Map<String, dynamic>? _order;
  Map<String, dynamic>? _nf;
  String? _error;
  bool _loading = false;
  bool _sending = false;
  final _qty = <int, TextEditingController>{};
  final _invoiceNumber = TextEditingController();

  ApiClient get api => widget.session.api;

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    _invoiceNumber.dispose();
    super.dispose();
  }

  /// `orderLineId:quantity,...` of the weighed quantities typed (0 when empty or invalid, which leaves the item out).
  String _linesQuery() => [for (final e in _qty.entries) '${e.key}:${parseDecimal(e.value.text.trim()) ?? 0}'].join(',');

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final order = await api.get('/api/sales/orders/${widget.id}') as Map<String, dynamic>;
      final nf = await api.get('/api/fiscal/preview/order/${widget.id}', _qty.isEmpty ? null : {'lines': _linesQuery()}) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _order = order;
          _nf = nf;
          _error = null;
          // The first load proposes what is still to ship; the weighed quantities typed afterwards are kept on the next loads.
          for (final l in (nf['orderLines'] as List? ?? const []).cast<Map<String, dynamic>>()) {
            if ((l['remaining'] as num) > 0) {
              _qty.putIfAbsent(l['orderLineId'] as int, () => TextEditingController(text: '${l['quantity']}'.replaceAll('.', ',')));
            }
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Creates the delivery with the weighed quantities, ships it and emits the NF (or takes the typed number when emission is off), then opens the delivery to continue with the certificate.
  Future<void> _dispatch(Map<String, dynamic> nf) async {
    final lines = <Map<String, dynamic>>[
      for (final e in _qty.entries)
        if ((parseDecimal(e.value.text.trim()) ?? 0) > 0) {'orderLineId': e.key, 'quantity': parseDecimal(e.value.text.trim())},
    ];
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Digite a quantidade pesada de pelo menos um item')));
      return;
    }
    final on = nf['fiscalEnabled'] == true;
    final typed = _invoiceNumber.text.trim();
    if (!on && typed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A emissão fiscal está desligada: digite o número da NF emitida fora do sistema')));
      return;
    }
    final total = fmtMoney(nf['invoiceTotal']);
    final ok = await confirm(
      context,
      on
          ? 'Emitir a NF ${nf['nextNumber']} (${nf['company'] ?? 'EBT'}) no valor de $total?\n\nA carga sai do estoque agora${nf['simulated'] == true ? ' (SEFAZ simulada: nada é enviado de verdade)' : ' e a nota é enviada à SEFAZ'}. Não dá para desfazer.'
          : 'Registrar a saída da carga com a NF $typed no valor de $total?\n\nA emissão fiscal está desligada: nada é enviado à SEFAZ. A carga sai do estoque agora.',
      confirmLabel: on ? 'Emitir NF e expedir' : 'Registrar saída',
    );
    if (!ok || !mounted) return;
    setState(() => _sending = true);
    try {
      final d = await api.post('/api/sales/orders/${widget.id}/dispatch', {
        'date': isoDate(DateTime.now()),
        'lines': lines,
        if (!on) 'invoiceNumber': typed,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Carga expedida${d['invoiceNumber'] == null ? '' : ' com a NF ${d['invoiceNumber']}'}. Próximo passo: certificado.')));
      await _load();
      if (mounted) await openDelivery(context, widget.session, d['id'] as int);
      if (mounted) await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// The weighed quantity of each item that still has something to ship; the preview below follows what is typed here.
  Widget _weighing(Map<String, dynamic> nf) {
    final items = (nf['orderLines'] as List? ?? const []).cast<Map<String, dynamic>>().where((l) => (l['remaining'] as num) > 0).toList();
    if (items.isEmpty) {
      return const NextStepCard(
        key: ValueKey('invoice-nothing-left'),
        title: 'Nada a expedir',
        message: 'Todos os itens deste pedido já saíram.',
        tone: Tone.success,
        icon: Icons.check_circle_outline,
      );
    }
    return Section(
      title: 'Carga e quantidade pesada',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'A OF volta da fábrica com o produto pesado, às vezes um pouco a mais ou a menos que o pedido. Digite o peso final de cada item: a NF e a baixa do estoque usam estes valores. Deixe em 0 o item que não vai nesta carga.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          gap,
          for (final l in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                key: ValueKey('invoice-qty-${l['orderLineId']}'),
                controller: _qty[l['orderLineId']],
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Item ${l['sequence']} · ${l['code']} (${l['unit']})',
                  helperText: 'Pedido: ${fmtNum(l['ordered'], 3)} · falta expedir: ${fmtNum(l['remaining'], 3)}',
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          if (nf['fiscalEnabled'] != true)
            TextField(
              key: const ValueKey('invoice-number'),
              controller: _invoiceNumber,
              decoration: const InputDecoration(
                labelText: 'Número da NF (emitida fora do sistema)',
                helperText: 'A emissão fiscal está desligada: o sistema só registra o número',
                border: OutlineInputBorder(),
              ),
            ),
          gap,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(key: const ValueKey('invoice-update'), onPressed: _loading || _sending ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Atualizar a prévia')),
              FilledButton.icon(
                key: const ValueKey('invoice-confirm'),
                onPressed: _sending || nf['ready'] != true ? null : () => _dispatch(nf),
                icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.receipt_long),
                label: Text(nf['fiscalEnabled'] == true ? 'Confirmar e emitir NF' : 'Confirmar saída com NF digitada'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = _order, nf = _nf;
    return Scaffold(
      appBar: AppBar(
        title: Text(o == null ? 'Emitir nota fiscal' : 'Emitir nota fiscal · ${o['reference']}', overflow: TextOverflow.ellipsis),
        actions: [IconButton(key: const ValueKey('invoice-refresh'), tooltip: 'Atualizar a simulação', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load)],
      ),
      body: _error != null && nf == null
          ? LoadError(message: _error!, onRetry: _load)
          : nf == null || o == null
          ? const RecordSkeleton()
          : RefreshIndicator(onRefresh: _load, child: _body(o, nf)),
    );
  }

  Widget _kv(String label, Object? value) {
    final text = value == null || '$value'.trim().isEmpty ? '—' : '$value';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  Widget _partySection(String title, Map<String, dynamic> p) => Section(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _kv('Nome', p['name']),
        _kv('CNPJ/CPF', p['document']),
        _kv('Inscrição estadual', p['stateRegistration']),
        _kv('Endereço', p['address']),
        _kv('Cidade/UF', [if (p['city'] != null) p['city'], if (p['uf'] != null) p['uf']].join(' / ')),
        _kv('CEP · IBGE', [if (p['zipCode'] != null) p['zipCode'], if (p['cityIbgeCode'] != null) p['cityIbgeCode']].join(' · ')),
      ],
    ),
  );

  Widget _problems(Map<String, dynamic> nf) {
    final problems = (nf['problems'] as List).cast<Map<String, dynamic>>();
    final blocking = problems.where((p) => p['blocking'] == true).length;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (nf['ready'] == true)
          NextStepCard(
            key: const ValueKey('invoice-ready'),
            title: 'Cadastros completos para emitir',
            message: problems.isEmpty ? 'Nada falta: a NF sairia com os dados abaixo.' : 'Nada bloqueia a emissão. Veja os avisos abaixo.',
            tone: Tone.success,
            icon: Icons.check_circle_outline,
          )
        else
          NextStepCard(
            key: const ValueKey('invoice-blocked'),
            title: blocking == 1 ? 'Falta 1 item para emitir' : 'Faltam $blocking itens para emitir',
            message: 'Complete os cadastros indicados e atualize a simulação.',
            tone: Tone.danger,
            icon: Icons.error_outline,
          ),
        if (problems.isNotEmpty) ...[
          gap,
          Section(
            title: 'Checklist',
            child: Column(
              key: const ValueKey('invoice-problems'),
              children: [
                for (final p in problems)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(p['blocking'] == true ? Icons.error_outline : Icons.info_outline, color: p['blocking'] == true ? theme.colorScheme.error : theme.colorScheme.tertiary),
                    title: Text('${p['area']}: ${p['message']}'),
                    subtitle: Text('Onde resolver: ${p['fix']}'),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _tax(Object? cst, Object? percent, Object? value) => 'CST $cst · ${fmtNum(percent)}% · R\$ ${fmtNum(value)}';

  Widget _items(Map<String, dynamic> nf) => Section(
    title: 'Itens',
    child: SimpleTable(
      columns: [
        ColumnSpec('Produto', (e) => '${e['code']} · ${fmt(e['description'])}'),
        ColumnSpec('NCM', (e) => fmt(e['ncm'])),
        ColumnSpec('Qtd', (e) => '${fmtNum(e['quantity'], 3)} ${e['unit']}', numeric: true),
        ColumnSpec('Preço', (e) => 'R\$ ${fmtNum(e['unitPrice'], 4)} (${e['priceSource']})', numeric: true),
        moneyCol('Total', 'total'),
        ColumnSpec('ICMS', (e) => _tax(e['icmsCst'], e['icmsPercent'], e['icmsValue'])),
        ColumnSpec('IPI', (e) => _tax(e['ipiCst'], e['ipiPercent'], e['ipiValue'])),
        ColumnSpec('Regra de imposto', (e) => fmt(e['taxSource'])),
      ],
      rows: (nf['lines'] as List).cast<Map<String, dynamic>>(),
    ),
  );

  Widget _body(Map<String, dynamic> o, Map<String, dynamic> nf) {
    final skip = o['quoteId'] == null ? 3 : 0;
    final installments = (nf['installments'] as List).cast<Map<String, dynamic>>();
    final transport = nf['transport'] as Map<String, dynamic>;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${o['reference']} · ${fmt(o['customerName'])}', style: Theme.of(context).textTheme.titleMedium),
        gap,
        StagePath(
          steps: flowSteps.sublist(skip),
          current: invoiceStep - skip,
          // Back to the order from any earlier step; the later steps live on the order too.
          onStep: (i) => i + skip == invoiceStep ? null : () => Navigator.maybePop(context),
        ),
        gap,
        NextStepCard(
          key: const ValueKey('invoice-simulation'),
          title: 'Prévia da nota fiscal',
          message:
              'Confira a NF abaixo. Só ao tocar em "Confirmar e emitir NF" a carga sai do estoque e a nota é emitida; depois vem o certificado e, por fim, a confirmação da entrega ao cliente.',
          tone: Tone.info,
          icon: Icons.receipt_long_outlined,
          actions: [
            OutlinedButton.icon(key: const ValueKey('invoice-back'), onPressed: () => Navigator.maybePop(context), icon: const Icon(Icons.arrow_back), label: const Text('Voltar ao pedido')),
          ],
        ),
        gap,
        _weighing(nf),
        gap,
        _problems(nf),
        gap,
        Section(
          title: 'Operação',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('CFOP', '${nf['cfop']} · ${fmt(nf['cfopDescription'])}'),
              _kv('Série · próximo número', '${nf['series']} · ${nf['nextNumber']}'),
              _kv('Ambiente', nf['environment'] == 'Production' ? 'Produção' : 'Homologação'),
              _kv('Emissão fiscal', nf['fiscalEnabled'] == true ? 'Ligada' : 'Desligada (NF digitada à mão na expedição)'),
              _kv('SEFAZ', nf['simulated'] == true ? 'Simulada (sem certificado A1)' : 'Real'),
            ],
          ),
        ),
        gap,
        _partySection(nf['company'] == null ? 'Emitente' : 'Emitente (${nf['company']})', nf['issuer'] as Map<String, dynamic>),
        gap,
        _partySection('Destinatário', nf['recipient'] as Map<String, dynamic>),
        gap,
        _items(nf),
        gap,
        Section(
          title: 'Totais',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Produtos', fmtMoney(nf['productsTotal'])),
              _kv('Frete', fmtMoney(nf['freightTotal'])),
              _kv('Base do ICMS', fmtMoney(nf['icmsBase'])),
              _kv('ICMS', fmtMoney(nf['icmsTotal'])),
              _kv('IPI', fmtMoney(nf['ipiTotal'])),
              _kv('PIS', fmtMoney(nf['pisTotal'])),
              _kv('COFINS', fmtMoney(nf['cofinsTotal'])),
              _kv('Total da nota', fmtMoney(nf['invoiceTotal'])),
            ],
          ),
        ),
        if (installments.isNotEmpty) ...[
          gap,
          Section(
            title: 'Duplicatas',
            child: SimpleTable(columns: [col('Parcela', 'sequence'), dateCol('Vencimento', 'dueDate'), moneyCol('Valor', 'amount')], rows: installments),
          ),
        ],
        gap,
        Section(
          title: 'Transporte e informações',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _kv('Frete', transport['mode']),
              _kv('Transportadora', transport['carrier']),
              _kv('Peso líquido', transport['netWeightKg'] == null ? null : '${fmtNum(transport['netWeightKg'], 3)} kg'),
              _kv('Informações complementares', nf['additionalInfo']),
            ],
          ),
        ),
      ],
    );
  }
}
