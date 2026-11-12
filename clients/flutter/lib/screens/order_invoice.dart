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

  /// Data of the load that goes on the NF and can be edited before confirming (sent with the dispatch; empty = the server's default).
  static const _extra = {
    'carrier': 'Transportadora',
    'vehiclePlate': 'Placa do veículo',
    'grossWeightKg': 'Peso bruto (kg)',
    'freight': r'Frete na NF (R$)',
    'cfop': 'CFOP (vazio = o do endereço de entrega ou 5101)',
    'lotNumber': 'Nº do lote',
    'notes': 'Observações da entrega',
  };
  static const _numericExtra = {'grossWeightKg', 'freight'};
  final _extraCtl = {for (final k in _extra.keys) k: TextEditingController()};

  ApiClient get api => widget.session.api;

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    _invoiceNumber.dispose();
    for (final c in _extraCtl.values) {
      c.dispose();
    }
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
        for (final e in _extraCtl.entries)
          if (e.value.text.trim().isNotEmpty) e.key: _numericExtra.contains(e.key) ? parseDecimal(e.value.text.trim()) : e.value.text.trim(),
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

  // ---- layout ---------------------------------------------------------------------------------------------------------------------------------------------

  /// Width from which the screen shows the NF on the left and the action panel (weighing, load data, total, confirm) beside it.
  static const _wide = 1000.0;

  @override
  Widget build(BuildContext context) {
    final o = _order, nf = _nf;
    return Scaffold(
      appBar: AppBar(
        title: Text(o == null ? 'Emitir nota fiscal' : 'Emitir nota fiscal · ${o['reference']}', overflow: TextOverflow.ellipsis),
        actions: [IconButton(key: const ValueKey('invoice-refresh'), tooltip: 'Atualizar a prévia', icon: const Icon(Icons.refresh), onPressed: _loading ? null : _load)],
      ),
      body: _error != null && nf == null
          ? LoadError(message: _error!, onRetry: _load)
          : nf == null || o == null
          ? const RecordSkeleton()
          : LayoutBuilder(builder: (context, box) => box.maxWidth >= _wide ? _wideBody(o, nf) : RefreshIndicator(onRefresh: _load, child: _narrowBody(o, nf))),
    );
  }

  Widget _wideBody(Map<String, dynamic> o, Map<String, dynamic> nf) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 8, 24), children: _preview(o, nf))),
      SizedBox(
        width: 410,
        child: ListView(padding: const EdgeInsets.fromLTRB(8, 16, 16, 24), children: [_actionPanel(nf)]),
      ),
    ],
  );

  Widget _narrowBody(Map<String, dynamic> o, Map<String, dynamic> nf) {
    final preview = _preview(o, nf);
    // Phones and narrow windows: the header and the checklist first, then the action panel, then the rest of the NF.
    return ListView(padding: const EdgeInsets.all(16), children: [...preview.take(3), _actionPanel(nf), gap, ...preview.skip(3)]);
  }

  // ---- left: the NF -----------------------------------------------------------------------------------------------------------------------------------------

  Widget _chip(String label, {Tone tone = Tone.neutral, IconData? icon}) => StatusBadge(label, tone: tone, icon: icon);

  /// Order header, path, short explanation and the facts of the operation as chips.
  Widget _header(Map<String, dynamic> o, Map<String, dynamic> nf) {
    final skip = o['quoteId'] == null ? 3 : 0;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${o['reference']} · ${fmt(o['customerName'])}', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
        const SizedBox(height: 10),
        StagePath(
          steps: flowSteps.sublist(skip),
          current: invoiceStep - skip,
          // Back to the order from any earlier step; the later steps live on the order too.
          onStep: (i) => i + skip == invoiceStep ? null : () => Navigator.maybePop(context),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            _chip('Emitente ${nf['company'] ?? 'EBT'}', icon: Icons.apartment_outlined),
            _chip('CFOP ${nf['cfop']} · ${fmt(nf['cfopDescription'])}', icon: Icons.swap_horiz),
            _chip('Série ${nf['series']} · nº ${nf['nextNumber']}', icon: Icons.tag),
            _chip(nf['environment'] == 'Production' ? 'Produção' : 'Homologação', tone: nf['environment'] == 'Production' ? Tone.warning : Tone.neutral),
            _chip(nf['fiscalEnabled'] == true ? 'Emissão ligada' : 'Emissão desligada', tone: nf['fiscalEnabled'] == true ? Tone.success : Tone.warning, icon: Icons.power_settings_new),
            _chip(nf['simulated'] == true ? 'SEFAZ simulada' : 'SEFAZ real', tone: nf['simulated'] == true ? Tone.info : Tone.success, icon: Icons.cloud_outlined),
          ],
        ),
        const SizedBox(height: 10),
        const NextStepCard(
          key: ValueKey('invoice-simulation'),
          title: 'Prévia da nota fiscal',
          message: 'Confira a NF, ajuste as quantidades pesadas e os dados da carga no painel e confirme. Depois vem o certificado e, por fim, a confirmação da entrega ao cliente.',
          tone: Tone.info,
          icon: Icons.receipt_long_outlined,
        ),
      ],
    );
  }

  Widget _party(String title, IconData icon, Map<String, dynamic> p) {
    final theme = Theme.of(context);
    String? join(List<Object?> parts, [String sep = ' · ']) {
      final v = parts.where((e) => e != null && '$e'.trim().isNotEmpty).join(sep);
      return v.isEmpty ? null : v;
    }

    Widget line(String? text, {String missing = '—'}) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(text ?? missing, style: text == null ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium),
    );
    return Section(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(fmt(p['name']), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
            ],
          ),
          line(join(['CNPJ/CPF ${fmt(p['document'])}', 'IE ${fmt(p['stateRegistration'])}'])),
          line(p['address'] as String?, missing: 'Endereço não informado'),
          line(join([join([p['city'], p['uf']], ' / '), if (p['zipCode'] != null) 'CEP ${p['zipCode']}', 'IBGE ${fmt(p['cityIbgeCode'])}'])),
        ],
      ),
    );
  }

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
            message: 'Complete os cadastros indicados e atualize a prévia.',
            tone: Tone.danger,
            icon: Icons.error_outline,
          ),
        if (problems.isNotEmpty) ...[
          const SizedBox(height: 8),
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

  /// One card per item of the NF: product on top, then quantity, price and the taxes as labelled figures that wrap with the width (a table with eight columns does not fit beside the action panel).
  Widget _items(Map<String, dynamic> nf) {
    final theme = Theme.of(context);
    Widget fact(String label, String value, {double width = 150}) => SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
    final rows = (nf['lines'] as List).cast<Map<String, dynamic>>();
    return Section(
      title: 'Itens da nota',
      child: Column(
        children: [
          for (final e in rows)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: theme.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(10)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Item ${e['sequence']} · ${e['code']}', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
                  Text(fmt(e['description']), style: theme.textTheme.bodySmall),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 16,
                    runSpacing: 10,
                    children: [
                      fact('NCM', fmt(e['ncm']), width: 90),
                      fact('Quantidade', '${fmtNum(e['quantity'], 3)} ${e['unit']}'),
                      fact('Preço unitário', 'R\$ ${fmtNum(e['unitPrice'], 4)}'),
                      fact('Origem do preço', fmt(e['priceSource'])),
                      fact('Total do item', fmtMoney(e['total'])),
                      fact('ICMS', _tax(e['icmsCst'], e['icmsPercent'], e['icmsValue']), width: 210),
                      fact('IPI', _tax(e['ipiCst'], e['ipiPercent'], e['ipiValue']), width: 210),
                      fact('Regra de imposto', fmt(e['taxSource']), width: 210),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A figure with its label, for the totals strip.
  Widget _metric(String label, Object? value, {bool strong = false}) {
    final theme = Theme.of(context);
    return Container(
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: strong ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 2),
          Text(fmtMoney(value), style: (strong ? theme.textTheme.titleMedium : theme.textTheme.bodyLarge)?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _totals(Map<String, dynamic> nf) => Section(
    title: 'Totais',
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _metric('Produtos', nf['productsTotal']),
        _metric('Frete', nf['freightTotal']),
        _metric('Base do ICMS', nf['icmsBase']),
        _metric('ICMS', nf['icmsTotal']),
        _metric('IPI', nf['ipiTotal']),
        _metric('PIS', nf['pisTotal']),
        _metric('COFINS', nf['cofinsTotal']),
        _metric('Total da nota', nf['invoiceTotal'], strong: true),
      ],
    ),
  );

  Widget _kv(String label, Object? value) {
    final text = value == null || '$value'.trim().isEmpty ? '—' : '$value';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 120, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  /// The NF as the preview builds it: parties side by side, items, totals, duplicatas next to transport, and the complementary text.
  List<Widget> _preview(Map<String, dynamic> o, Map<String, dynamic> nf) {
    final installments = (nf['installments'] as List).cast<Map<String, dynamic>>();
    final transport = nf['transport'] as Map<String, dynamic>;
    final issuer = _party(nf['company'] == null ? 'Emitente' : 'Emitente (${nf['company']})', Icons.factory_outlined, nf['issuer'] as Map<String, dynamic>);
    final recipient = _party('Destinatário', Icons.local_shipping_outlined, nf['recipient'] as Map<String, dynamic>);
    final dup = Section(
      title: 'Duplicatas',
      child: installments.isEmpty
          ? Text('Sem duplicatas (pagamento à vista ou sem prazo).', style: Theme.of(context).textTheme.bodySmall)
          : SimpleTable(columns: [col('Parcela', 'sequence'), dateCol('Vencimento', 'dueDate'), moneyCol('Valor', 'amount')], rows: installments),
    );
    final trans = Section(
      title: 'Transporte',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Frete', transport['mode']),
          _kv('Transportadora', transport['carrier']),
          _kv('Peso líquido', transport['netWeightKg'] == null ? null : '${fmtNum(transport['netWeightKg'], 3)} kg'),
        ],
      ),
    );
    return [
      _header(o, nf),
      const SizedBox(height: 12),
      _problems(nf),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, box) => box.maxWidth >= 640
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: issuer), const SizedBox(width: 12), Expanded(child: recipient)])
            : Column(children: [issuer, const SizedBox(height: 12), recipient]),
      ),
      const SizedBox(height: 12),
      _items(nf),
      const SizedBox(height: 12),
      _totals(nf),
      const SizedBox(height: 12),
      LayoutBuilder(
        builder: (context, box) => box.maxWidth >= 640
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: dup), const SizedBox(width: 12), Expanded(child: trans)])
            : Column(children: [dup, const SizedBox(height: 12), trans]),
      ),
      const SizedBox(height: 12),
      Section(title: 'Informações complementares', child: SelectableText(fmt(nf['additionalInfo']))),
    ];
  }

  // ---- right: the action panel ------------------------------------------------------------------------------------------------------------------------------

  Widget _qtyField(Map<String, dynamic> l) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(
      key: ValueKey('invoice-qty-${l['orderLineId']}'),
      controller: _qty[l['orderLineId']],
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        isDense: true,
        labelText: 'Item ${l['sequence']} · ${l['code']} (${l['unit']})',
        helperText: 'Pedido ${fmtNum(l['ordered'], 3)} · falta expedir ${fmtNum(l['remaining'], 3)}',
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _extraField(String key) => SizedBox(
    width: key == 'notes' || key == 'cfop' || key == 'carrier' ? double.infinity : 175,
    child: TextField(
      key: ValueKey('invoice-extra-$key'),
      controller: _extraCtl[key],
      keyboardType: _numericExtra.contains(key) ? const TextInputType.numberWithOptions(decimal: true) : null,
      minLines: key == 'notes' ? 2 : 1,
      maxLines: key == 'notes' ? 3 : 1,
      decoration: InputDecoration(isDense: true, labelText: _extra[key], border: const OutlineInputBorder()),
    ),
  );

  Widget _step(BuildContext context, int n, String title) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 10),
    child: Row(
      children: [
        CircleAvatar(radius: 11, backgroundColor: Theme.of(context).colorScheme.primary, child: Text('$n', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onPrimary))),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
      ],
    ),
  );

  /// Everything the person does before the truck leaves, in order: what is weighed, the load data, the total to be invoiced and the confirmation.
  Widget _actionPanel(Map<String, dynamic> nf) {
    final theme = Theme.of(context);
    final on = nf['fiscalEnabled'] == true;
    final oldServer = nf['orderLines'] == null;
    final items = (nf['orderLines'] as List? ?? const []).cast<Map<String, dynamic>>().where((l) => (l['remaining'] as num) > 0).toList();
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.local_shipping_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(child: Text('Saída da carga', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
                _chip(nf['ready'] == true ? 'Pronta' : 'Pendências', tone: nf['ready'] == true ? Tone.success : Tone.danger, icon: nf['ready'] == true ? Icons.check : Icons.error_outline),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: theme.colorScheme.primaryContainer, borderRadius: BorderRadius.circular(12)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total da nota', style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
                  Text(fmtMoney(nf['invoiceTotal']), style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.onPrimaryContainer)),
                  Text(
                    on ? 'NF nº ${nf['nextNumber']} · série ${nf['series']} (${nf['company'] ?? 'EBT'})' : 'Emissão desligada: a NF é digitada à mão',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onPrimaryContainer),
                  ),
                ],
              ),
            ),
            if (oldServer) ...[
              const SizedBox(height: 12),
              const NextStepCard(
                key: ValueKey('invoice-old-server'),
                title: 'API desatualizada',
                message: 'O servidor ainda não tem a versão nova desta tela (quantidade pesada e emissão na saída). Atualize a API e abra a tela de novo.',
                tone: Tone.warning,
                icon: Icons.system_update_alt,
              ),
            ] else if (items.isEmpty) ...[
              const SizedBox(height: 12),
              const NextStepCard(key: ValueKey('invoice-nothing-left'), title: 'Nada a expedir', message: 'Todos os itens deste pedido já saíram.', tone: Tone.success, icon: Icons.check_circle_outline),
            ] else ...[
              _step(context, 1, 'Quantidade pesada'),
              Text(
                'A OF volta da fábrica com o produto pesado, às vezes um pouco a mais ou a menos que o pedido. A NF e a baixa do estoque usam estes valores; 0 deixa o item fora da carga.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              for (final l in items) _qtyField(l),
              _step(context, 2, 'Dados da carga'),
              Wrap(spacing: 10, runSpacing: 10, children: [for (final k in _extra.keys) _extraField(k)]),
              if (!on) ...[
                _step(context, 3, 'Número da NF'),
                TextField(
                  key: const ValueKey('invoice-number'),
                  controller: _invoiceNumber,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Número da NF (emitida fora do sistema)',
                    helperText: 'A emissão fiscal está desligada: o sistema só registra o número',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                key: const ValueKey('invoice-confirm'),
                style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                onPressed: _sending || nf['ready'] != true ? null : () => _dispatch(nf),
                icon: _sending ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.receipt_long),
                label: Text(on ? 'Confirmar e emitir NF' : 'Confirmar saída com NF digitada'),
              ),
              if (nf['ready'] != true)
                Padding(padding: const EdgeInsets.only(top: 6), child: Text('Resolva as pendências do checklist para liberar a emissão.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error))),
              const SizedBox(height: 8),
              OutlinedButton.icon(key: const ValueKey('invoice-update'), onPressed: _loading || _sending ? null : _load, icon: const Icon(Icons.refresh), label: const Text('Atualizar a prévia')),
            ],
          ],
        ),
      ),
    );
  }
}
