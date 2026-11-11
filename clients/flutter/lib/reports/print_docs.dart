import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../api.dart';
import '../entities.dart';
import '../labels.dart';
import '../screens/customers.dart' show fmtDocument;
import '../widgets/print_panel.dart' show printPdf;
import 'pdf_theme.dart';
import 'pt_text.dart';

/// Dados da empresa no cabeçalho do orçamento, lidos dos parâmetros fiscais (`GET /api/fiscal/settings`). O que não foi cadastrado não é impresso:
/// nada de CNPJ ou endereço inventado numa folha que vai ao cliente.
class _Issuer {
  const _Issuer({this.name = 'EBT', this.lines = const []});

  final String name;
  final List<String> lines;

  static Future<_Issuer> load(ApiClient api) async {
    try {
      final s = await api.get('/api/fiscal/settings') as Map<String, dynamic>;
      String v(String key) => _s(s[key]).trim();
      final name = v('tradeName').isNotEmpty ? v('tradeName') : (v('companyName').isNotEmpty ? v('companyName') : 'EBT');
      final cnpj = fmtDocument(s['cnpj']);
      final ie = v('stateRegistration');
      final street = [v('street'), v('number')].where((e) => e.isNotEmpty).join(', ');
      final city = [v('city'), v('uf')].where((e) => e.isNotEmpty).join('/');
      final address = [street, v('district'), city, if (v('zipCode').isNotEmpty) 'CEP ${v('zipCode')}'].where((e) => e.isNotEmpty).join(' - ');
      return _Issuer(
        name: name,
        lines: [
          if (cnpj.isNotEmpty || ie.isNotEmpty) [if (cnpj.isNotEmpty) 'CNPJ: $cnpj', if (ie.isNotEmpty) 'I.E.: $ie'].join('   '),
          if (address.isNotEmpty) address,
          if (v('phone').isNotEmpty) 'Tel.: ${v('phone')}',
        ],
      );
    } catch (e) {
      // Settings are context: without them the sheet prints the company name only.
      debugPrint('print_docs: issuer data unavailable, printing the name only: $e');
      return const _Issuer();
    }
  }
}

/// What makes a quote PDF not final, in words ("RASCUNHO", "SUBSTITUÍDA pela revisão PROP 8A"...), or null for a quote that may go to the customer.
/// The PDF carries it in a banner on every page; screens can ask before printing one.
String? quotePrintWarning(Map<String, dynamic> q) {
  if (q['supersededById'] != null) return 'SUBSTITUÍDA pela revisão ${q['supersededBy'] ?? ''}'.trim();
  return switch (q['status']) {
    'Draft' => 'RASCUNHO · ainda não enviado ao cliente',
    'PendingApproval' => 'RASCUNHO · aguardando a autorização do gerente',
    'Approved' => 'RASCUNHO · ainda não enviado ao cliente',
    'Cancelled' => 'CANCELADO',
    'Expired' => 'VALIDADE EXPIRADA',
    _ => null,
  };
}

/// The quote as it will be once the e-mail registers the send: Sent, with the send time and the validity the server will set (today + validity
/// days when none was set). The PDF that goes out with that e-mail is built from this copy, so it carries no draft banner and no "dias após o envio".
Map<String, dynamic> quoteAsSent(Map<String, dynamic> q, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final days = q['validityDays'];
  return {
    ...q,
    'status': 'Sent',
    'sentAt': at.toUtc().toIso8601String(),
    'validUntil': q['validUntil'] ?? (days is int ? isoDate(DateTime(at.year, at.month, at.day + days)) : null),
  };
}

const _generalConditions =
    'Preços sujeitos a confirmação na data do pedido. Impostos conforme legislação vigente. '
    'Prazo de entrega em dias úteis, contado a partir da aprovação do orçamento pelo cliente e da aprovação de desenhos, quando aplicável.';

/// Theme with the embedded fonts, for documents built outside this file.
Future<pw.ThemeData> printTheme() => _theme();

Future<pw.ThemeData> _theme() => pdfTheme();

pw.TextStyle _b([double size = 9]) => pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: size);
pw.TextStyle _n([double size = 9]) => pw.TextStyle(fontSize: size);

String _s(Object? v) => v == null ? '' : '$v';

pw.Widget _header(String docTitle, String reference, _Issuer issuer, {String? banner}) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [
    pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.center,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [pw.Text(issuer.name, style: _b(14)), for (final l in issuer.lines) pw.Text(l, style: _n(8))],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [pw.Text(docTitle, style: _b(13)), pw.Text(reference, style: _b(16))],
        ),
      ],
    ),
    if (banner != null)
      pw.Container(
        width: double.infinity,
        margin: const pw.EdgeInsets.only(top: 6),
        padding: const pw.EdgeInsets.symmetric(vertical: 4),
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.red700, width: 1.5)),
        child: pw.Text(banner, style: const pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold, color: PdfColors.red700)),
      ),
    pw.Divider(thickness: 1),
  ],
);

pw.Widget _box(String title, List<(String, String)> fields) => pw.Container(
  width: double.infinity,
  padding: const pw.EdgeInsets.all(6),
  decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey500, width: 0.5)),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(title, style: _b(9)),
      pw.SizedBox(height: 3),
      pw.Wrap(
        spacing: 18,
        runSpacing: 3,
        children: [
          for (final (k, v) in fields)
            if (v.isNotEmpty) pw.RichText(text: pw.TextSpan(children: [pw.TextSpan(text: '$k: ', style: _b(8)), pw.TextSpan(text: v, style: _n(8))])),
        ],
      ),
    ],
  ),
);

pw.Widget _cell(String t, {bool bold = false, bool right = false}) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
  child: pw.Text(t, style: bold ? _b(8) : _n(8), textAlign: right ? pw.TextAlign.right : pw.TextAlign.left),
);

pw.Widget _table(List<String> headers, List<List<String>> rows, {required List<num> flex, Set<int> right = const {}}) => pw.Table(
  columnWidths: {for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i].toDouble())},
  border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.3), bottom: pw.BorderSide(color: PdfColors.grey600, width: 0.5)),
  children: [
    pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.grey300),
      children: [for (var i = 0; i < headers.length; i++) _cell(headers[i], bold: true, right: right.contains(i))],
    ),
    for (final r in rows) pw.TableRow(children: [for (var i = 0; i < r.length; i++) _cell(r[i], right: right.contains(i))]),
  ],
);

pw.Widget _totals(List<(String, String)> rows) => pw.Align(
  alignment: pw.Alignment.centerRight,
  child: pw.SizedBox(
    width: 220,
    child: pw.Column(
      children: [
        for (final (i, (k, v)) in rows.indexed)
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [pw.Text(k, style: i == rows.length - 1 ? _b(10) : _n(9)), pw.Text(v, style: i == rows.length - 1 ? _b(10) : _n(9))],
            ),
          ),
      ],
    ),
  ),
);

pw.Widget _text(String title, String body) => pw.Column(
  crossAxisAlignment: pw.CrossAxisAlignment.start,
  children: [pw.SizedBox(height: 8), pw.Text(title, style: _b(9)), pw.SizedBox(height: 2), pw.Text(body, style: _n(8))],
);

pw.Widget _footer(pw.Context c) => pw.Align(alignment: pw.Alignment.centerRight, child: pw.Text('Página ${c.pageNumber}/${c.pagesCount}', style: _n(7)));

Future<Uint8List> _build(String title, List<pw.Widget> Function() body, {PdfPageFormat? format, pw.Widget Function(pw.Context)? header}) async {
  final doc = pw.Document(title: title, theme: await _theme());
  doc.addPage(pw.MultiPage(pageFormat: format ?? PdfPageFormat.a4, margin: const pw.EdgeInsets.all(28), footer: _footer, header: header, build: (_) => body()));
  return savePdf(doc);
}

Future<Map<String, dynamic>?> _customer(ApiClient api, Object? id) async {
  if (id == null) return null;
  try {
    return await api.get('/api/customers/$id') as Map<String, dynamic>;
  } on ApiException catch (e) {
    // A customer that no longer exists prints blank; any other failure stops the print instead of leaving the customer out.
    if (e.status == 404) return null;
    rethrow;
  }
}

/// The rows of the item table; [materials] is the material the customer usually gets for each product, shown after the description when the line does not already say it.
List<List<String>> _itemRows(List<Map<String, dynamic>> lines, [Map<Object?, String> materials = const {}]) => [
  for (final l in lines)
    [
      _s(l['sequence']),
      '${l['productCode']}${l['customerPartNumber'] == null ? '' : ' (${l['customerPartNumber']})'}',
      () {
        final description = _s(l['description']);
        final material = _preferUsual(_materialFromDescription(description), materials[l['productId']] ?? '');
        return material.isEmpty || description.contains(material) ? description : '$description · $material';
      }(),
      fmt(l['quantity']),
      _s(l['unit']),
      fmtNum(l['unitPrice'], 4),
      fmt(l['ipiPercent']),
      fmt(l['icmsPercent']),
      fmtNum(l['total']),
      l['deliveryDate'] != null ? fmtDay(l['deliveryDate']) : (l['leadTimeDays'] != null ? '${l['leadTimeDays']} dias úteis' : ''),
    ],
];

const _itemHeaders = ['Item', 'Produto', 'Descrição', 'Qtd.', 'Un.', 'Preço unit.', 'IPI %', 'ICMS %', 'Valor estimado', 'Entrega*'];
const List<num> _itemFlex = [0.5, 1.6, 2.9, 0.9, 0.6, 1.3, 0.7, 0.8, 1.5, 1.3];
const _itemRight = {3, 5, 6, 7, 8};

/// Orçamento (PROP N).
Future<Uint8List> buildQuotePdf(ApiClient api, Map<String, dynamic> q) async {
  final customer = await _customer(api, q['customerId']);
  final chosen = await _orderAddress(api, q['customerId'], q['addressId']);
  // The same customer data as the pedido interno: the company's own address, CNPJ, I.E. with its dots, contact and the customer code; the delivery place apart from it.
  final c = _CustomerBlock(_s(q['customerName']), customer, _s(q['addressText']), chosen: chosen);
  final issuer = await _Issuer.load(api);
  final banner = quotePrintWarning(q);
  final t = q['totals'] as Map<String, dynamic>;
  final lines = (q['lines'] as List).cast<Map<String, dynamic>>();
  final date = q['sentAt'] ?? q['createdAt'];
  // What this customer always asks for on each product: the material ("BK DIN 2393") and the observation ("ISENTO DE OLEO E GRAXA").
  final usual = <Object?, ({String material, String note})>{for (final l in lines) l['productId']: await _usual(api, q['customerId'], l['productId'])};
  final pickup = _s(q['freight']) == 'CustomerPickup';
  final address = [c.address, c.district, c.city.isEmpty ? '' : (c.uf.isEmpty ? c.city : '${c.city}-${c.uf}'), c.zip].where((e) => e.isNotEmpty).join(' - ');
  final ownNotes = cleanOrderNote(_s(q['notes']));
  final productNotes = <String>[];
  for (final l in lines) {
    final n = cleanOrderNote(usual[l['productId']]?.note ?? '');
    if (n.isNotEmpty && !productNotes.contains(n) && !ownNotes.contains(n)) productNotes.add(n);
  }
  final notes = [if (ownNotes.isNotEmpty) ownNotes, ...productNotes].join('\n');
  return _build('Orçamento ${q['reference']}', () => [
    _box('Cliente', [
      ('Nome', c.name),
      ('Cód. cliente', c.code),
      ('CNPJ', c.cnpj),
      ('I.E.', c.ie),
      ('Endereço', address),
      ('Contato', c.contact),
      ('Telefone', c.phone),
      ('E-mail', c.email),
      if (!pickup) ('Local de entrega', c.delivery),
    ]),
    pw.SizedBox(height: 6),
    _box('Orçamento', [
      ('Nº', _s(q['reference'])),
      ('Data', date == null ? '' : fmtDay(_s(date).split('T').first)),
      ('Validade', q['validUntil'] != null ? fmtDay(q['validUntil']) : '${q['validityDays']} dias após o envio'),
      ('Prazo', fmt(q['paymentTermName'] ?? q['customPaymentTerm'])),
      ('Frete', freightTerms[q['freight']] ?? fmt(q['freight'])),
      ('Contato', [q['contactName'], q['contactEmail']].whereType<String>().join(' · ')),
      ('Ref. do cliente', fmt(q['customerReference'])),
      ('Pedido do cliente', _s(q['customerPo'])),
    ]),
    pw.SizedBox(height: 8),
    _table(_itemHeaders, _itemRows(lines, {for (final e in usual.entries) e.key: e.value.material}), flex: _itemFlex, right: _itemRight),
    pw.SizedBox(height: 8),
    _totals([('Total dos produtos', fmtMoney(t['products'])), ('IPI', fmtMoney(t['ipi'])), ('Total do orçamento', fmtMoney(t['total']))]),
    if (lines.any((l) => l['leadTimeDays'] != null && l['deliveryDate'] == null))
      pw.Padding(padding: const pw.EdgeInsets.only(top: 6), child: pw.Text('* Prazo de entrega em dias úteis, contado a partir da data em que o cliente aprovar este orçamento.', style: const pw.TextStyle(fontSize: 8.5))),
    if (notes.isNotEmpty) _text('Observações', notes),
    _text('Condições gerais', _s(q['conditions']).isNotEmpty ? _s(q['conditions']) : _generalConditions),
  ], header: (_) => _header('Orçamento', _s(q['reference']), issuer, banner: banner));
}

// ---- Formulários internos (modelos oficiais: Pedido Interno de Venda e Ordem de Fabricação) ----

const _ink = PdfColors.black;
const _blue = PdfColor.fromInt(0xFF1F3864);
const _sectionFill = PdfColor.fromInt(0xFFDCE6F1);
const _refRed = PdfColor.fromInt(0xFFFF0000);
const _checkYellow = PdfColor.fromInt(0xFFFFFF00);

pw.TextStyle _t(double size, {bool bold = false, PdfColor color = _ink}) => pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color);

const _line = pw.BorderSide(color: _ink, width: 1);
const _under = pw.BoxDecoration(border: pw.Border(bottom: _line));
const _leftUnder = pw.BoxDecoration(border: pw.Border(left: _line, bottom: _line));

pw.Widget _frame(List<pw.Widget> children) => pw.Container(
  decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.5)),
  child: pw.Column(children: children),
);

/// Linha de largura total com borda inferior; `cells` é uma lista de (flex, widget).
pw.Widget _formRow(List<(int, pw.Widget)> cells, {double? height, bool lastRow = false}) => pw.Container(
  height: height ?? 16,
  decoration: lastRow ? null : _under,
  child: pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      for (final (i, (flex, w)) in cells.indexed)
        pw.Expanded(
          flex: flex,
          child: pw.Container(
            decoration: i == 0 ? null : const pw.BoxDecoration(border: pw.Border(left: _line)),
            padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2),
            alignment: pw.Alignment.centerLeft,
            child: w,
          ),
        ),
    ],
  ),
);

pw.Widget _lbl(String label, [String value = '', double size = 8.5]) => pw.RichText(
  text: pw.TextSpan(
    children: [
      pw.TextSpan(text: label, style: _t(size, bold: true)),
      if (value.isNotEmpty) pw.TextSpan(text: ' $value', style: _t(size, bold: true, color: _blue)),
    ],
  ),
);

pw.Widget _centered(pw.Widget w) => pw.Center(child: w);

pw.Widget _sectionTitle(String t, {double size = 9, bool fill = false, bool bold = true}) => pw.Container(
  width: double.infinity,
  alignment: pw.Alignment.center,
  padding: const pw.EdgeInsets.symmetric(vertical: 2),
  decoration: pw.BoxDecoration(color: fill ? _sectionFill : null, border: const pw.Border(bottom: _line)),
  child: pw.Text(t, style: _t(size, bold: bold)),
);

pw.Widget _checkBox(bool checked, {double w = 22, double h = 12}) => pw.Container(
  width: w,
  height: h,
  alignment: pw.Alignment.center,
  decoration: pw.BoxDecoration(color: checked ? _checkYellow : null, border: pw.Border.all(color: _ink, width: 0.8)),
  child: checked ? pw.Text('X', style: _t(9, bold: true)) : null,
);

pw.Widget _checkItem(String label, bool checked, {bool boxFirst = true, double size = 8.5}) {
  final box = _checkBox(checked);
  final text = pw.Text(label, style: _t(size, bold: true));
  return pw.Row(mainAxisSize: pw.MainAxisSize.min, children: boxFirst ? [box, pw.SizedBox(width: 4), text] : [text, pw.SizedBox(width: 4), box]);
}

pw.Widget _titleBar(String title, String reference) => pw.Container(
  height: 38,
  decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.5)),
  child: pw.Row(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Expanded(child: pw.Center(child: pw.Text(title, style: _t(15, bold: true)))),
      pw.Container(
        width: 100,
        alignment: pw.Alignment.center,
        decoration: const pw.BoxDecoration(border: pw.Border(left: pw.BorderSide(color: _ink, width: 1.5))),
        child: pw.Text(reference, style: _t(14, color: _refRed)),
      ),
    ],
  ),
);

pw.Widget _checkLabel(bool checked, String label) => pw.Row(children: [_checkBox(checked), pw.SizedBox(width: 6), pw.Text(label, style: _t(8.5, bold: true))]);

pw.Widget _codeLabel(String label, String value) => pw.Row(children: [pw.Text('$label  ', style: _t(8.5, bold: true)), pw.Text(value, style: _t(9, bold: true, color: _blue))]);

/// [novelty] comes from GET /api/sales/customers/{id}/novelty: without it neither "novo" nor "já fornecido" box is ticked (blank is better than wrong).
pw.Widget _identBox({required String productCode, required String customerCode, ({bool customerNew, bool itemNew})? novelty}) => _frame([
  _formRow([
    (1, _checkLabel(novelty?.customerNew == true, 'CLIENTE NOVO')),
    (1, _checkLabel(novelty != null && !novelty.customerNew, 'CLIENTE CADASTRADO')),
    (1, _codeLabel('CÓD. PRODUTO:', productCode)),
  ], height: 26),
  _formRow([
    (1, _checkLabel(novelty?.itemNew == true, 'ITEM NOVO')),
    (1, _checkLabel(novelty != null && !novelty.itemNew, 'ITEM JÁ FORNECIDO')),
    (1, _codeLabel('CÓD. CLIENTE:', customerCode)),
  ], height: 26, lastRow: true),
]);

/// [origin] is how the order arrived (Email, Fax, Verbal); System or null tick nothing.
pw.Widget _orderedBy(Object? origin) => pw.Padding(
  padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 20),
  child: pw.Row(
    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
    children: [pw.Text('PEDIDO POR:', style: _t(8.5, bold: true)), _checkItem('E-MAIL', origin == 'Email'), _checkItem('FAX', origin == 'Fax'), _checkItem('VERBAL', origin == 'Verbal')],
  ),
);

/// Cliente novo / item novo of the order or OF, or null when the server does not answer.
Future<({bool customerNew, bool itemNew})?> _novelty(ApiClient api, Object? customerId, Object? productId, {Object? exceptOrderId, Object? exceptProductionId}) async {
  if (customerId == null) return null;
  try {
    final q = [if (productId != null) 'productId=$productId', if (exceptOrderId != null) 'exceptOrderId=$exceptOrderId', if (exceptProductionId != null) 'exceptProductionId=$exceptProductionId'].join('&');
    final r = await api.get('/api/sales/customers/$customerId/novelty?$q') as Map<String, dynamic>;
    return (customerNew: r['customerNew'] == true, itemNew: r['itemNew'] == true);
  } catch (e) {
    debugPrint('print_docs: novelty unavailable, boxes stay blank: $e');
    return null;
  }
}

/// The delivery address chosen on the order (not just the customer's default), or null.
Future<Map<String, dynamic>?> _orderAddress(ApiClient api, Object? customerId, Object? addressId) async {
  if (customerId == null || addressId == null) return null;
  try {
    final list = (await api.get('/api/customers/$customerId/addresses') as List).cast<Map<String, dynamic>>();
    for (final a in list) {
      if (a['id'] == addressId) return a;
    }
  } catch (e) {
    debugPrint('print_docs: order address unavailable, using the customer default: $e');
  }
  return null;
}

Future<Map<String, dynamic>?> _productById(ApiClient api, Object? id) async {
  if (id == null) return null;
  try {
    return await api.get('/api/products/$id') as Map<String, dynamic>;
  } on ApiException catch (e) {
    if (e.status != 404) rethrow;
    return null;
  }
}

/// "MATERIAL STKM 11A SAE 1008" -> "STKM 11A SAE 1008": the form already says "Especificação do material".
/// A description that is only the tube's name ("TUBO-C 08,00 X 0,90 X 6000 MM") says nothing about the material and gives "".
String _materialFromDescription(String d) =>
    RegExp(r'^\s*TUBO', caseSensitive: false).hasMatch(d) ? '' : d.replaceFirst(RegExp(r'^\s*MATERIAL\s*[:\-]?\s*', caseSensitive: false), '').trim();

/// What the customer's old orders say for this product: the material ("BK DIN 2393") and the observation they usually carried ("ISENTO DE OLEO E GRAXA"); '' when unknown.
Future<({String material, String note})> _usual(ApiClient api, Object? customerId, Object? productId) async {
  if (customerId == null || productId == null) return (material: '', note: '');
  try {
    final r = await api.get('/api/sales/material-suggestion?customerId=$customerId&productId=$productId') as Map<String, dynamic>;
    return (material: _s(r['material']), note: _s(r['note']));
  } on ApiException {
    return (material: '', note: '');
  }
}

/// An observation without the customer's purchase-order prefix ("PEDIDO Nº 102956 - C/ TRATAMENTO TERMICO" -> "C/ TRATAMENTO TERMICO"): the paper says what the tube needs, not the PO number.
String cleanOrderNote(String note) => note
    // The note the system wrote on older OFs ("PV 40 item 10 · pedido cliente 102956"): the PV and the customer's PO have their own fields on the paper.
    .replaceFirst(RegExp(r'^\s*PV\s*\d+\s+item\s+\d+\s*(?:·\s*pedido cliente\s+[^·]*)?(?:·\s*)?', caseSensitive: false), '')
    .replaceFirst(RegExp(r'^\s*(PEDIDO(\s+DE\s+COMPRAS?)?|ORDEM\s+DE\s+COMPRA|O\.?\s?C\.?)\s*(N[º°o]\.?)?\s*:?\s*[\d.\-/]*\s*[-–:]*\s*', caseSensitive: false), '')
    .trim();

/// A material written without the delivery condition ("SAE 1005/1008 - DIN 2393") gives way to the customer's usual one when it names the same norm and has the
/// condition ("BK DIN 2393"): the customer buys the tube in that condition, the steel grade alone does not say it.
String _preferUsual(String written, String usual) {
  if (usual.isEmpty) return written;
  if (written.isEmpty) return usual;
  final condition = RegExp(r'\b(GBK|NBK|BK)\b', caseSensitive: false);
  final norm = RegExp(r'(?:DIN|EN)\s*(\d{3,5})', caseSensitive: false);
  final u = norm.firstMatch(usual);
  final w = norm.firstMatch(written);
  return condition.hasMatch(usual) && !condition.hasMatch(written) && u != null && w != null && u.group(1) == w.group(1) ? usual : written;
}

/// Endereço, CNPJ, IE e contato do cliente (preferindo o cadastro da empresa, depois o endereço padrão).
class _CustomerBlock {
  /// [chosen] is the address picked on the order: when given it wins over the company/default address.
  _CustomerBlock(String rawName, Map<String, dynamic>? c, String addressText, {Map<String, dynamic>? chosen}) : name = ptText(rawName) {
    final co = c?['company'] as Map<String, dynamic>?;
    // The customer block is the customer's own (main) address and data; the address chosen on the order is only where to deliver (FRETE). A customer without a main
    // address in the cadastro falls back to its default delivery address.
    final ad = c?['defaultAddress'] as Map<String, dynamic>?;
    final first = co;
    final second = ad ?? chosen;
    String pick(String key) => _s(first?[key]).isNotEmpty ? _s(first?[key]) : _s(second?[key]);
    String pickOf(Map<String, dynamic>? a, String key) => _s(a?[key]);
    final street = pick('street');
    address = street.isEmpty ? ptText(addressText) : ptStreet(street, pick('number'));
    district = ptText(pick('district'));
    city = ptText(pick('city'));
    uf = pick('uf').toUpperCase();
    zip = ptZip(pick('zipCode'));
    cnpj = fmtDocument(first?['document'] ?? second?['document']);
    ie = ptIe(pick('stateRegistration'), uf);
    final contactRaw = [co?['contact'], chosen?['buyer'], ad?['buyer']].map(_s).firstWhere((e) => e.isNotEmpty, orElse: () => '');
    // Where to deliver: the address chosen on the order when it is another place than the main address, else the main address.
    final dStreet = pickOf(chosen, 'street');
    final sameAsMain = chosen == null || dStreet.isEmpty || (ptText(dStreet) == ptText(pick('street')) && pickOf(chosen, 'number') == pick('number'));
    delivery = sameAsMain
        ? [address, district, city.isEmpty ? '' : (uf.isEmpty ? city : '$city-$uf'), zip].where((e) => e.isNotEmpty).join(' ')
        : [
            ptStreet(dStreet, pickOf(chosen, 'number')),
            ptText(pickOf(chosen, 'district')),
            ptText(pickOf(chosen, 'city')).isEmpty ? '' : (pickOf(chosen, 'uf').isEmpty ? ptText(pickOf(chosen, 'city')) : '${ptText(pickOf(chosen, 'city'))}-${pickOf(chosen, 'uf').toUpperCase()}'),
            ptZip(pickOf(chosen, 'zipCode')),
          ].where((e) => e.isNotEmpty).join(' ');
    contact = ptText(contactRaw);
    phone = ptPhone(pick('phone'));
    email = ptEmail(pick('email'));
    // The code the paper sheets always carried ("CÓD. CLIENTE"); the id of the database is not a customer code and is never printed in its place.
    code = _s(c?['clientCode']).isNotEmpty ? _s(c?['clientCode']) : _s(c?['legacyCode']);
  }

  final String name;
  late final String address, district, city, uf, zip, cnpj, ie, contact, phone, email, code, delivery;
}

pw.Widget _customerBox(_CustomerBlock c) => _frame([
  _formRow([(1, _lbl('CLIENTE:', c.name))]),
  _formRow([(1, _lbl('END:', c.address))]),
  _formRow([(1, _lbl('BAIRRO:', c.district)), (1, _lbl('MUNICÍPIO:', c.city))]),
  _formRow([(1, _lbl('CEP:', c.zip)), (1, _lbl('ESTADO:', c.uf))]),
  _formRow([(1, _lbl('CNPJ:', c.cnpj)), (1, _lbl('I.E:', c.ie))]),
  _formRow([(1, _lbl('CONTATO:', c.contact)), (1, _lbl('TEL/ FAX:', c.phone))]),
  _formRow([(1, _lbl('E-MAIL:', c.email))], lastRow: true),
]);

pw.Widget _specBox({required String dimensions, required String quantity, required String material, required String delivery, required String notes, String customerPo = ''}) => _frame([
  _sectionTitle('ESPECIFICAÇÃO', size: 10),
  _formRow([(1, _lbl('DIMENSÕES DO TUBO (MM):', dimensions)), (1, _lbl('QUANTIDADE (KG/PÇ):', quantity))]),
  _formRow([(1, _lbl('ESPECIFICAÇÃO DO MATERIAL:', material)), (1, _lbl('DATA DE ENTREGA:', delivery))]),
  _formRow([(2, _lbl('OBSERVAÇÕES:', notes)), (1, _lbl('PEDIDO DO CLIENTE:', customerPo))], lastRow: true),
]);

/// A form that always prints on ONE A4 sheet: the blocks keep their size while they fit and shrink together when the process has many operations, and the sheet is centered on the page both ways, so nothing is cut off
/// and no second page is needed.
Future<Uint8List> _formsFlow(String title, List<pw.Widget> blocks) async {
  final doc = pw.Document(title: title, theme: await _theme());
  const margin = pw.EdgeInsets.fromLTRB(36, 28, 36, 28);
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: margin,
      build: (_) => pw.FittedBox(
        fit: pw.BoxFit.scaleDown,
        alignment: pw.Alignment.center,
        child: pw.SizedBox(width: PdfPageFormat.a4.width - margin.horizontal, child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: blocks)),
      ),
    ),
  );
  return savePdf(doc);
}

Future<Uint8List> _forms(String title, List<pw.Widget> pages) async {
  final doc = pw.Document(title: title, theme: await _theme());
  for (final p in pages) {
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.fromLTRB(36, 28, 36, 28), build: (_) => p));
  }
  return savePdf(doc);
}

/// Diâmetro, espessura e comprimento da especificação da linha do pedido ("Ø25,4 × e1,5 × c6000"), ou vazio.
String _specMeasures(Object? spec) {
  if (spec is! Map) return '';
  return [
    if (spec['outsideDiameter'] != null) 'Ø${fmt(spec['outsideDiameter'])}',
    if (spec['thickness'] != null) 'e${fmt(spec['thickness'])}',
    if (spec['length'] != null) 'c${fmt(spec['length'])}',
  ].join(' × ');
}

/// Norma e condição de fornecimento da especificação da linha, ou vazio.
String _specStandard(Object? spec) {
  if (spec is! Map) return '';
  return [spec['standard'], if (spec['condition'] != null) deliveryConditions[spec['condition']]].whereType<Object>().join(' · ');
}

String _qty(num q, String unit) => '${fmtNum(q, q == q.roundToDouble() ? 0 : 3)} $unit'.trim();

/// Pedido interno de venda (PV N). Uma página por item, conforme o modelo.
Future<Uint8List> buildSalesOrderPdf(ApiClient api, Map<String, dynamic> o) async {
  final customer = await _customer(api, o['customerId']);
  final chosen = await _orderAddress(api, o['customerId'], o['addressId']);
  final c = _CustomerBlock(_s(o['customerName']), customer, _s(o['addressText']), chosen: chosen);
  final lines = (o['lines'] as List).cast<Map<String, dynamic>>();
  // Per item: the product (measures) and whether the customer / item is new. Loaded before the pages are built.
  final products = <Object?, Map<String, dynamic>?>{for (final l in lines) l['productId']: await _productById(api, l['productId'])};
  final novelty = <Object?, ({bool customerNew, bool itemNew})?>{for (final l in lines) l['productId']: await _novelty(api, o['customerId'], l['productId'], exceptOrderId: o['id'])};
  final usual = <Object?, ({String material, String note})>{for (final l in lines) l['productId']: await _usual(api, o['customerId'], l['productId'])};
  final billTo = _s(o['billTo']);
  final created = _s(o['createdAt']).split('T').first;
  final term = _s(o['paymentTermName'] ?? o['customPaymentTerm']);
  final freight = _s(o['freight']);
  // The order's own observation wins; without one, the observation the customer usually puts on this product goes on the paper.
  String notesFor(Object? productId) {
    final own = cleanOrderNote(_s(o['notes']));
    return own.isNotEmpty ? own : cleanOrderNote(usual[productId]?.note ?? '');
  }

  final pages = <pw.Widget>[
    for (final l in lines)
      () {
        final qty = (l['quantity'] as num?) ?? 0;
        final price = (l['unitPrice'] as num?) ?? 0;
        final ipi = (l['ipiPercent'] as num?) ?? 0;
        // The paper's total includes IPI (the screen's line total does not): it starts from the value the server saved, so both agree on the base.
        final base = (l['total'] as num?) ?? double.parse((qty * price).toStringAsFixed(2));
        final total = double.parse((base * (1 + ipi / 100)).toStringAsFixed(2));
        final description = _s(l['description']).isNotEmpty ? _s(l['description']) : _s(l['productCode']);
        final spec = l['spec'];
        final product = products[l['productId']];
        // Measures: the line's own spec, else the product's cadastro. The line's description is the material ("MATERIAL STKM 11A SAE 1008"), never the measures.
        final specMeasures = _specMeasures(spec);
        final measures = specMeasures.isNotEmpty ? '$specMeasures mm' : _tubeDimensions(product, '');
        final standard = _specStandard(spec);
        final fromDescription = _materialFromDescription(description);
        final usualMaterial = usual[l['productId']]?.material ?? '';
        final materialText = _preferUsual(standard.isNotEmpty ? standard : (fromDescription.isNotEmpty ? fromDescription : usualMaterial), usualMaterial);
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            _titleBar('PEDIDO INTERNO DE VENDA', _s(o['reference'])),
            pw.SizedBox(height: 4),
            _identBox(productCode: _s(l['productCode']), customerCode: c.code, novelty: novelty[l['productId']]),
            _orderedBy(o['origin']),
            _customerBox(c),
            pw.SizedBox(height: 4),
            _specBox(
              dimensions: measures.isEmpty ? ptText(_s(product?['name']).isNotEmpty ? product!['name'] : description) : measures,
              quantity: _qty(qty, _s(l['unit'])),
              material: materialText,
              delivery: fmtDay(l['dueDate']),
              notes: notesFor(l['productId']),
              customerPo: _s(o['customerPo']),
            ),
            pw.SizedBox(height: 4),
            _salesTerms(price: fmtMoney(price), perKg: _s(l['unit']).toUpperCase() == 'KG', icms: fmt(l['icmsPercent']), ipi: '${fmt(ipi)}%', total: fmtMoney(total), term: term, billTo: billTo),
            pw.SizedBox(height: 4),
            _freightBox(freight: freight, place: c.delivery),
            pw.SizedBox(height: 22),
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(horizontal: 40),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Column(children: [pw.Text(created.isEmpty ? '' : fmtDay(created), style: _t(8.5, bold: true)), pw.Text('DATA', style: _t(8.5, bold: true))]),
                  pw.Text('ASSINATURA DO RESPONSÁVEL DE VENDAS', style: _t(8.5, bold: true)),
                ],
              ),
            ),
          ],
        );
      }(),
  ];
  return _forms('Pedido de venda ${o['reference']}', pages);
}

pw.Widget _salesTerms({required String price, required bool perKg, required String icms, required String ipi, required String total, required String term, String billTo = ''}) => pw.Container(
  decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.5)),
  padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 40),
  child: pw.Column(
    children: [
      pw.Text('CONDIÇÕES DE VENDA', style: _t(10, bold: true)),
      pw.SizedBox(height: 8),
      pw.Container(
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.2)),
        padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [pw.Text('PREÇO DE VENDA:', style: _t(8.5, bold: true)), pw.Text(price, style: _t(9, bold: true, color: _blue)), _checkItem('KG', perKg), _checkItem('PÇ', !perKg)],
        ),
      ),
      pw.SizedBox(height: 8),
      pw.Container(
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.2)),
        padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 3),
        child: pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Text('IMPOSTOS :', style: _t(8.5, bold: true)),
            pw.SizedBox(width: 12),
            pw.Column(children: [_lbl('ICMS:', icms), pw.SizedBox(height: 2), _lbl('I.P.I:', ipi)]),
          ],
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Container(
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.2)),
        child: pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Container(width: 110, height: 40, alignment: pw.Alignment.center, child: pw.Text('VALOR  TOTAL R\$', style: _t(8.5, bold: true))),
            pw.Container(
              width: 150,
              height: 40,
              alignment: pw.Alignment.center,
              decoration: const pw.BoxDecoration(border: pw.Border(left: pw.BorderSide(color: _ink, width: 1.2))),
              child: pw.Text(total, style: _t(16, color: _blue)),
            ),
          ],
        ),
      ),
      pw.SizedBox(height: 10),
      pw.Container(
        width: double.infinity,
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.2)),
        child: pw.Text('PRAZO DE PAGAMENTO: $term', style: _t(8.5, bold: true, color: _blue)),
      ),
      // "FATURAR PARA": only the company chosen when the order was created (EBT or BST), ticked.
      if (billTo == 'Ebt' || billTo == 'Bts') ...[
        pw.SizedBox(height: 6),
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 40),
          decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.2)),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            children: [pw.Text('FATURAR PARA:', style: _t(9, bold: true)), pw.SizedBox(width: 24), _checkItem(billTo == 'Ebt' ? 'EBT' : 'BST', true, size: 10)],
          ),
        ),
      ],
      pw.SizedBox(height: 6),
    ],
  ),
);

pw.Widget _freightBox({required String freight, required String place}) => pw.Container(
  decoration: pw.BoxDecoration(border: pw.Border.all(color: _ink, width: 1.5)),
  padding: const pw.EdgeInsets.fromLTRB(10, 4, 10, 6),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Center(child: pw.Text('FRETE', style: _t(10, bold: true))),
      pw.SizedBox(height: 4),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(children: [pw.Text('CLIENTE RETIRA:   ', style: _t(8.5, bold: true)), _checkBox(freight == 'CustomerPickup', w: 30)]),
          pw.Column(
            children: [
              pw.Row(children: [_checkBox(freight == 'Cif', w: 30), pw.SizedBox(width: 8), pw.Text('ENTREGA POR NOSSA CONTA', style: _t(8.5, bold: true))]),
              // The customer collects: there is no place to deliver to.
              if (freight != 'CustomerPickup') ...[
                pw.SizedBox(height: 3),
                pw.Text('LOCAL DE ENTREGA:', style: _t(8.5, bold: true)),
                pw.SizedBox(width: 200, child: pw.Text(place, style: _t(8.5, bold: true, color: _blue), textAlign: pw.TextAlign.center)),
              ],
            ],
          ),
        ],
      ),
      pw.SizedBox(height: 4),
      pw.Row(
        children: [
          pw.Text('TRANSPORTADORA: ', style: _t(8.5, bold: true)),
          // FOB: the carrier is the customer's; pickup: the customer comes with its own vehicle.
          if (freight == 'Fob') pw.Text('indicada pelo cliente (FOB)', style: _t(8.5, bold: true, color: _blue)),
          if (freight == 'CustomerPickup') pw.Text('o cliente retira na fábrica', style: _t(8.5, bold: true, color: _blue)),
        ],
      ),
      pw.SizedBox(height: 4),
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [pw.Text('CNPJ: ______________________________________________', style: _t(8.5, bold: true)), pw.Text('I.E: _________________________________', style: _t(8.5, bold: true))],
      ),
    ],
  ),
);

const _opFlex = [8, 32, 17, 10, 10, 23];

/// The resource column of a process row: the machine; for the final inspection what the paper always said ("Visual/Dimensional"); "Terceiro" for outside work.
String _opResource(Map<String, dynamic> op) {
  if (op['external'] == true) return 'Terceiro';
  final name = _s(op['machineName']);
  if (RegExp(r'inspe[cç]', caseSensitive: false).hasMatch(name) || RegExp(r'inspe[cç]', caseSensitive: false).hasMatch(_s(op['description']))) return 'Visual/Dimensional';
  return name.isNotEmpty ? ptText(name) : _s(op['machineCode']);
}

/// Printable width of the A4 page (margins 36 + 36) and the room the text of a process column really has (padding 3 + 3, border 1).
const _opPageWidth = 595.28 - 72;
double _opTextWidth(int column) => _opPageWidth * _opFlex[column] / _opFlex.fold<int>(0, (a, b) => a + b) - 7;

/// Lays out the text of a process cell so it always fits and never breaks a word: one line at the normal size, else two lines (breaking at spaces and
/// after a slash, so "Visual/Dimensional" becomes "Visual/" + "Dimensional") at a smaller size. Widths are estimated, the paper has no room to measure.
({double size, List<String> lines}) opCellFit(String text, double width) {
  final t = text.trim();
  if (t.isEmpty) return (size: 8.5, lines: const []);
  final tokens = [for (final m in RegExp(r'[^\s/]+/?|/').allMatches(t)) m.group(0)!];
  double w(String s, double size) => s.length * size * 0.56;
  for (final (size, maxLines) in const [(8.5, 1), (7.0, 2), (6.5, 2), (6.0, 2)]) {
    final lines = <String>[''];
    for (final tok in tokens) {
      final cur = lines.last;
      final joined = cur.isEmpty ? tok : '$cur${cur.endsWith('/') ? '' : ' '}$tok';
      if (cur.isEmpty || w(joined, size) <= width) {
        lines[lines.length - 1] = joined;
      } else {
        lines.add(tok);
      }
    }
    if (lines.length <= maxLines && lines.every((l) => w(l, size) <= width)) return (size: size, lines: lines);
  }
  return (size: 6.0, lines: t.length > 1 && tokens.length > 1 ? [tokens.take((tokens.length + 1) ~/ 2).join(' '), tokens.skip((tokens.length + 1) ~/ 2).join(' ')] : [t]);
}

/// A text cell of the process table, fitted to the column (see [opCellFit]).
pw.Widget _opText(String text, int column) {
  final fit = opCellFit(text, _opTextWidth(column));
  if (fit.lines.isEmpty) return pw.SizedBox();
  return pw.Column(
    mainAxisSize: pw.MainAxisSize.min,
    children: [for (final l in fit.lines) pw.Text(l, style: _t(fit.size), textAlign: pw.TextAlign.center)],
  );
}

pw.Widget _opCell(pw.Widget child, int i, {double height = 17}) => pw.Expanded(
  flex: _opFlex[i],
  child: pw.Container(height: height, alignment: pw.Alignment.center, padding: const pw.EdgeInsets.symmetric(horizontal: 3), decoration: i == 0 ? _under : _leftUnder, child: child),
);

pw.Widget _opRow(List<pw.Widget> cells) => pw.Row(children: [for (final (i, w) in cells.indexed) _opCell(w, i)]);

String _mm(Object? v) => v is num ? fmtNum(v, v == v.roundToDouble() ? 0 : 2) : '';

/// Dimensões do tubo a partir do cadastro do produto (engenharia); sem medidas, usa o nome.
String _tubeDimensions(Map<String, dynamic>? p, String fallback) {
  if (p == null) return fallback;
  final size = p['shape'] == 'Rectangular' || p['shape'] == 1
      ? [_mm(p['widthMm']), _mm(p['heightMm'])].where((e) => e.isNotEmpty).join(' x ')
      : (_mm(p['diameterMm']).isEmpty ? '' : 'Ø ${_mm(p['diameterMm'])}');
  final parts = [size, _mm(p['thicknessMm']), _mm(p['lengthMm'])].where((e) => e.isNotEmpty).toList();
  return parts.isEmpty ? fallback : '${parts.join(' x ')} mm';
}

/// Especificação do material: matérias-primas da estrutura (BOM) da ordem.
String _materialSpec(List<Map<String, dynamic>> mats) =>
    mats.map((m) => _s(m['description']).isNotEmpty ? _s(m['description']) : _s(m['code'])).where((e) => e.isNotEmpty).toSet().join('; ');

/// Ordem de fabricação (OF N), conforme o modelo oficial.
Future<Uint8List> buildProductionOrderPdf(ApiClient api, Map<String, dynamic> o) async {
  final customer = await _customer(api, o['customerId']);
  // The sales order the OF came from gives the delivery address and how the order arrived (e-mail, fax, verbal).
  Map<String, dynamic>? salesOrder;
  if (o['salesOrderId'] != null) {
    try {
      salesOrder = await api.get('/api/sales/orders/${o['salesOrderId']}') as Map<String, dynamic>;
    } on ApiException catch (e) {
      if (e.status != 404) rethrow;
    }
  }
  final chosen = await _orderAddress(api, o['customerId'], salesOrder?['addressId']);
  final c = _CustomerBlock(_s(customer?['name']), customer, _s(salesOrder?['addressText']), chosen: chosen);
  final novelty = await _novelty(api, o['customerId'], o['productId'], exceptProductionId: o['id'], exceptOrderId: o['salesOrderId']);
  Map<String, dynamic>? product;
  try {
    product = await api.get('/api/products/${o['productId']}') as Map<String, dynamic>;
  } on ApiException catch (e) {
    // The measures on the OF come from the product: only a deleted product may print without them.
    if (e.status != 404) rethrow;
  }
  final ops = (o['operations'] as List).cast<Map<String, dynamic>>();
  final mats = (o['materials'] as List).cast<Map<String, dynamic>>();
  final qty = (o['quantity'] as num?) ?? 0;
  final rawMaterial = mats.isEmpty ? '' : (_s(mats.first['description']).isNotEmpty ? _s(mats.first['description']) : _s(mats.first['code']));
  // Without a BOM the material is the one written on the sales order line.
  final orderLine = ((salesOrder?['lines'] as List?) ?? const []).cast<Map<String, dynamic>>().where((l) => l['productId'] == o['productId']).firstOrNull;
  var orderMaterial = orderLine == null ? '' : _materialFromDescription(_s(orderLine['description']));
  final usual = await _usual(api, o['customerId'], o['productId']);
  if (orderMaterial.isEmpty) orderMaterial = usual.material;
  final materialText = _preferUsual(_materialSpec(mats).isNotEmpty ? _materialSpec(mats) : orderMaterial, usual.material);
  // Observation: the OF's own, else the one the customer usually puts on this product; never with the purchase-order number in front.
  final ofNotes = cleanOrderNote(_s(o['notes'])).isNotEmpty ? cleanOrderNote(_s(o['notes'])) : cleanOrderNote(usual.note);
  final blankRows = ops.length >= 5 ? 0 : 10 - ops.length * 2;
  final none = pw.SizedBox();
  pw.Widget small(String t) => pw.Text(t, style: _t(8.5));
  pw.Widget head(String t, {bool left = true, double? height, double? width}) => pw.Container(
    width: width,
    height: height,
    alignment: pw.Alignment.center,
    decoration: left ? _leftUnder : _under,
    child: pw.Text(t, style: _t(8, bold: true), textAlign: pw.TextAlign.center),
  );

  final blocks = <pw.Widget>[
      _titleBar('ORDEM DE FABRICAÇÃO', _s(o['customerPo']).isNotEmpty ? _s(o['customerPo']) : _s(o['reference'])),
      pw.SizedBox(height: 4),
      _identBox(productCode: _s(o['productCode']), customerCode: c.code, novelty: novelty),
      _orderedBy(salesOrder?['origin']),
      _customerBox(c),
      pw.SizedBox(height: 4),
      _specBox(dimensions: _tubeDimensions(product, _s(o['productName'])), quantity: _qty(qty, _s(o['productUnit'])), material: materialText, delivery: fmtDay(o['dueDate']), notes: ofNotes, customerPo: _s(o['customerPo'])),
      _frame([
        _sectionTitle('PROCESSO', fill: true),
        _formRow([(1, _centered(small('Matéria-Prima:'))), (2, small(_s(o['rawMaterial']).isNotEmpty ? _s(o['rawMaterial']) : rawMaterial)), (1, _centered(small('Lote'))), (1, none)], height: 17),
        _formRow([(2, _lbl('Tubo Primário (Perfilar):', '', 8)), (3, pw.Center(child: pw.Text(_s(o['primaryTube']), style: _t(9.5, bold: true))))], height: 20, lastRow: true),
      ]),
      pw.SizedBox(height: 4),
      _frame([
        _sectionTitle('PROCESSOS SECUNDÁRIOS', size: 8.5, fill: true),
        pw.Row(
          children: [
            pw.Expanded(flex: _opFlex[0], child: head('Nº Operação', left: false, height: 30)),
            pw.Expanded(flex: _opFlex[1], child: head('Descrição da Operação', height: 30)),
            pw.Expanded(flex: _opFlex[2], child: head('Requisitos/\nTolerância (mm)', height: 30)),
            pw.Expanded(
              flex: _opFlex[3] + _opFlex[4],
              child: pw.Column(children: [head('MEDIDAS', height: 15, width: double.infinity), pw.Row(children: [pw.Expanded(child: head('INÍCIO', height: 15)), pw.Expanded(child: head('FINAL', height: 15))])]),
            ),
            pw.Expanded(flex: _opFlex[5], child: pw.Column(children: [head('Recursos necessários', height: 15, width: double.infinity), head('Máq. / Ferramenta', height: 15, width: double.infinity)])),
          ],
        ),
        for (final op in ops) ...[
          _opRow([
            small(_s(op['sequence'])),
            _opText(ptText(op['description']), 1),
            _opText(_s(op['tolerance']), 2),
            small(_s(op['measureStart'])),
            small(_s(op['measureEnd'])),
            _opText(_opResource(op), 5),
          ]),
          _opRow([none, none, none, none, none, none]),
        ],
        for (var i = 0; i < blankRows; i++) _opRow([none, none, none, none, none, none]),
      ]),
      pw.SizedBox(height: 4),
      _frame([
        pw.Container(
          width: double.infinity,
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          decoration: const pw.BoxDecoration(color: _sectionFill, border: pw.Border(bottom: _line)),
          child: pw.Text('SOLICITAÇÃO DE EMISSÃO DE NOTA ( S.E.N.F)', style: _t(11, bold: false)),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 10),
          child: pw.Column(
            children: [
              pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [_checkItem('FATURAMENTO', false, size: 10), _checkItem('DEVOLUÇÃO', false, size: 10), _checkItem('BENEFICIAMENTO', false, size: 10)]),
              pw.SizedBox(height: 4),
              pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, children: [_checkItem('SISTEMISTA', false, size: 10), pw.SizedBox(width: 40), _checkItem('SPOT', false, size: 10)]),
            ],
          ),
        ),
        pw.Container(decoration: const pw.BoxDecoration(border: pw.Border(top: _line)), child: pw.SizedBox(width: double.infinity)),
        _formRow([
          (2, _centered(pw.Text('QUANTIDADE', style: _t(8, bold: true)))),
          (2, none),
          (2, _centered(pw.Text('UNIDADE', style: _t(8, bold: true)))),
          (1, none),
          (2, _centered(pw.Text('VOLUMES', style: _t(8, bold: true)))),
          (1, none),
        ], height: 17, lastRow: true),
      ]),
      pw.SizedBox(height: 4),
      _frame([
        pw.Container(
          width: double.infinity,
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          decoration: const pw.BoxDecoration(color: _sectionFill, border: pw.Border(bottom: _line)),
          child: pw.Text('INSPEÇÃO FINAL', style: _t(11)),
        ),
        _formRow([
          (3, _centered(pw.Text('ESPECIFICAÇÕES:\n(CONFORME PI E ANÁLISE DE VIABILIDADE)', style: _t(5.5), textAlign: pw.TextAlign.center))),
          (1, _centered(pw.Text('MIN', style: _t(8)))),
          (1, _centered(pw.Text('MAX', style: _t(8)))),
          (3, _centered(pw.Text('ESPECIFICAÇÕES:\n(CONFORME PI E ANÁLISE DE VIABILIDADE)', style: _t(5.5), textAlign: pw.TextAlign.center))),
          (1, _centered(pw.Text('MIN', style: _t(8)))),
          (1, _centered(pw.Text('MAX', style: _t(8)))),
        ], height: 26),
        _formRow([(3, _centered(small('DIAM EXT:'))), (1, none), (1, none), (3, _centered(small('ESPESSURA:'))), (1, none), (1, none)], height: 18),
        _formRow([(3, _centered(small('DIAM INT:(se solicitado)'))), (1, none), (1, none), (3, _centered(small('COMPRIMENTO:'))), (1, none), (1, none)], height: 18),
        _formRow([(2, _centered(small('DATA:'))), (3, _centered(small('/          /'))), (3, _centered(small('RESPONSÁVEL:'))), (2, none)], height: 18),
        _formRow([
          (2, _centered(small('SITUAÇÃO'))),
          (2, pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, children: [small('APROVADO'), pw.SizedBox(width: 4), _checkBox(false, w: 26)])),
          (2, pw.Row(mainAxisAlignment: pw.MainAxisAlignment.center, children: [small('REPROVADO'), pw.SizedBox(width: 4), _checkBox(false, w: 26)])),
          (2, small('RNC:')),
        ], height: 20, lastRow: true),
      ]),
  ];
  return _formsFlow('Ordem de fabricação ${o['reference']}', blocks);
}

/// Ficha do cliente: the contact data of one customer on one sheet (company, main address, contact, commercial terms and the delivery places).
Future<Uint8List> buildCustomerContactPdf(ApiClient api, Map<String, dynamic> c) async {
  final issuer = await _Issuer.load(api);
  var places = <Map<String, dynamic>>[];
  try {
    final r = await api.get('/api/customers/${c['id']}/addresses');
    final list = r is List ? r : (r is Map && r['items'] is List ? r['items'] as List : const []);
    places = list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  } on ApiException catch (e) {
    // The sheet still prints without the delivery places; a failure other than "not there" stops it instead of leaving them out silently.
    if (e.status != 404) rethrow;
  }
  final co = (c['company'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
  String line(Map<String, dynamic> a) => [
    ptStreet(a['street'], a['number']),
    _s(a['complement']),
    ptText(a['district']),
    [ptText(a['city']), _s(a['uf']).toUpperCase()].where((e) => e.isNotEmpty).join('/'),
    ptZip(a['zipCode']),
  ].where((e) => e.isNotEmpty).join(' - ');
  final code = _s(c['clientCode']).isNotEmpty ? _s(c['clientCode']) : _s(c['legacyCode']);
  final trade = ptText(c['tradeName']);
  final tax = [
    if (co['ipiPercent'] is num) 'IPI ${fmt(co['ipiPercent'])}%',
    if (co['icmsPercent'] is num) 'ICMS ${fmt(co['icmsPercent'])}%',
  ].join(' · ');
  return _build(
    'Ficha do cliente ${c['name']}',
    () => [
      pw.Text(ptText(c['name']), style: _b(15)),
      if (trade.isNotEmpty) pw.Text(trade, style: _n(10)),
      pw.SizedBox(height: 10),
      _box('Dados da empresa', [
        ('CNPJ/CPF', fmtDocument(co['document'])),
        ('Inscrição estadual', ptIe(co['stateRegistration'], co['uf'])),
        ('Contribuinte de ICMS', co['icmsContributor'] == true ? 'Sim' : 'Não'),
        ('Código do cliente', _s(c['clientCode'])),
        ('Código antigo', _s(c['legacyCode'])),
        ('Situação', c['active'] == true ? 'Ativo' : 'Inativo'),
      ]),
      pw.SizedBox(height: 6),
      _box('Endereço principal', [('Endereço', line(co))]),
      pw.SizedBox(height: 6),
      _box('Contato', [('Contato', ptText(co['contact'])), ('E-mail', ptEmail(co['email'])), ('Telefone', ptPhone(co['phone']))]),
      pw.SizedBox(height: 6),
      _box('Condições comerciais', [
        ('Prazo padrão', _s(co['paymentTermName'])),
        ('Limite de crédito', co['creditLimit'] is num ? 'R\$ ${fmtMoney(co['creditLimit'])}' : ''),
        ('Impostos usuais', tax),
      ]),
      if (_s(co['taxNote']).trim().isNotEmpty) _text('Impostos nos pedidos anteriores', _s(co['taxNote']).trim()),
      if (places.isNotEmpty) ...[
        pw.SizedBox(height: 10),
        pw.Text('Locais de entrega', style: _b(10)),
        pw.SizedBox(height: 3),
        for (final (i, a) in places.indexed)
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: _box(i == 0 ? 'Local padrão' : 'Local ${i + 1}', [('Endereço', line(a)), ('Contato', ptText(a['buyer'])), ('E-mail', ptEmail(a['email'])), ('Telefone', ptPhone(a['phone']))]),
          ),
      ],
    ],
    header: (_) => _header('Ficha do cliente', code, issuer),
  );
}

/// Customer list as a landscape spreadsheet: one row per customer, the header row repeated on every page, page numbers and the total at the end.
/// [filters] are lines describing what narrowed the list (search text, situation); they print under the title.
Future<Uint8List> buildCustomersListPdf(ApiClient api, List<Map<String, dynamic>> customers, {List<String> filters = const []}) async {
  final issuer = await _Issuer.load(api);
  final doc = pw.Document(title: 'Lista de clientes', theme: await _theme());
  const headers = ['Código', 'Cliente', 'CNPJ/CPF', 'Insc. estadual', 'Cidade/UF', 'Contato', 'Telefone', 'E-mail', 'Prazo', 'Limite (R\$)', 'IPI', 'ICMS', 'Situação'];
  const flex = <double>[1.1, 3.6, 2.2, 1.9, 2.1, 1.9, 1.9, 3.0, 1.6, 1.5, 0.8, 0.8, 1.0];
  const right = {9, 10, 11};
  String pct(Object? v) => v is num ? '${fmt(v)}%' : '';
  List<String> row(Map<String, dynamic> c) {
    final co = (c['company'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final name = ptText(c['name']);
    final trade = ptText(c['tradeName']);
    final city = [ptText(co['city']), _s(co['uf']).toUpperCase()].where((e) => e.isNotEmpty).join('/');
    return [
      _s(c['clientCode']).isNotEmpty ? _s(c['clientCode']) : _s(c['legacyCode']),
      trade.isEmpty || trade == name ? name : '$name\n$trade',
      fmtDocument(co['document']),
      ptIe(co['stateRegistration'], co['uf']),
      city,
      ptText(co['contact']),
      ptPhone(co['phone']),
      ptEmail(co['email']),
      _s(co['paymentTermName']),
      co['creditLimit'] is num ? fmtMoney(co['creditLimit']) : '',
      pct(co['ipiPercent']),
      pct(co['icmsPercent']),
      c['active'] == true ? 'Ativo' : 'Inativo',
    ];
  }

  final now = DateTime.now();
  final stamp = '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}';
  final count = '${customers.length} ${customers.length == 1 ? 'cliente' : 'clientes'}';
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(24),
      header: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(children: [pw.Expanded(child: pw.Text(issuer.name, style: _b(12))), pw.Text('Lista de clientes', style: _b(13))]),
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
          columnWidths: {for (var i = 0; i < flex.length; i++) i: pw.FlexColumnWidth(flex[i])},
          border: const pw.TableBorder(horizontalInside: pw.BorderSide(color: PdfColors.grey400, width: 0.3), bottom: pw.BorderSide(color: PdfColors.grey600, width: 0.5)),
          // The header row is drawn again at the top of every page the table spills onto.
          children: [
            pw.TableRow(
              repeat: true,
              decoration: const pw.BoxDecoration(color: PdfColors.grey300),
              children: [for (var i = 0; i < headers.length; i++) _cell(headers[i], bold: true, right: right.contains(i))],
            ),
            for (final c in customers) pw.TableRow(children: [for (final (i, v) in row(c).indexed) _cell(v, right: right.contains(i))]),
          ],
        ),
        pw.SizedBox(height: 8),
        pw.Text('Total: $count', style: _b(9)),
      ],
    ),
  );
  return savePdf(doc, offThread: customers.length > 150);
}

/// What the customer print does for a selection: one customer gets its sheet (portrait, [buildCustomerContactPdf]), two or more get the list
/// (landscape, [buildCustomersListPdf]). The sheet reads the delivery places from the API, so [customers] may be the rows of the list.
Future<Uint8List> buildCustomersPdf(ApiClient api, List<Map<String, dynamic>> customers, {List<String> filters = const []}) =>
    customers.length == 1 ? buildCustomerContactPdf(api, customers.single) : buildCustomersListPdf(api, customers, filters: filters);

/// Simulação de preço: one A4 sheet with the measures, the suggested price and the similar sales it came from. It is an internal working paper,
/// never a proposal. [s] is the plain data the simulator screen collects (see `PriceSimulatorPanel`): shape, measures, spec, customer, quantity,
/// netKg, grossKg, lossPercent, pricePerKg, pricePerPiece, low, high, total, confidence, reason, warning, markupPercent, costPerKg, margin, note, date, similar.
Future<Uint8List> buildSimulationPdf(ApiClient api, Map<String, dynamic> s) async {
  final issuer = await _Issuer.load(api);
  String money(Object? v, [String unit = '']) => v is num ? '${fmtMoney(v)}$unit' : '';
  String weight(Object? kg) => kg is num ? (kg < 10 ? '${fmtNum(kg * 1000, 0)} g' : '${fmtNum(kg, 3)} kg') : '';
  String measure(Map<String, dynamic> e) {
    String p(Object? v) => v is num ? fmt(v) : '?';
    return 'ø ${p(e['diameter'])} × ${p(e['thickness'])} × ${p(e['length'])}';
  }

  final similar = [for (final e in (s['similar'] as List? ?? const [])) (e as Map).cast<String, dynamic>()].take(10).toList();
  final date = _s(s['date']).split('T').first;
  final q = s['quantity'];
  final markup = s['markupPercent'];
  return _build('Simulação de preço', () => [
    _box('Tubo', [
      ('Formato', _s(s['shape'])),
      ('Medidas', _s(s['measures'])),
      ('Especificação', _s(s['spec'])),
      ('Cliente', _s(s['customer'])),
      ('Quantidade', q is num && q > 0 ? '${fmt(q)} ${q == 1 ? 'peça' : 'peças'}' : ''),
    ]),
    pw.SizedBox(height: 6),
    _box('Peso', [('Líquido', weight(s['netKg'])), ('Bruto', weight(s['grossKg'])), ('Perda', s['lossPercent'] is num ? '${fmtNum(s['lossPercent'], 1)}%' : '')]),
    pw.SizedBox(height: 6),
    _box('Preço sugerido', [
      ('Por kg', money(s['pricePerKg'], '/kg')),
      ('Por peça', money(s['pricePerPiece'], '/peça')),
      ('Faixa', s['low'] is num && s['high'] is num ? '${money(s['low'])} a ${money(s['high'])}/kg' : ''),
      ('Total', money(s['total'])),
      ('Confiança', _s(s['confidence'])),
      ('Acréscimo', markup is num && markup > 0 ? '${fmt(markup)}%' : ''),
      ('Custo do aço', money(s['costPerKg'], '/kg')),
      ('Margem', _s(s['margin'])),
    ]),
    _text('Base da sugestão', [_s(s['reason']), _s(s['warning'])].where((e) => e.isNotEmpty).join('\n')),
    if (_s(s['note']).isNotEmpty) _text('Observação', _s(s['note'])),
    pw.SizedBox(height: 8),
    pw.Text('Vendas parecidas', style: _b(9)),
    pw.SizedBox(height: 2),
    if (similar.isEmpty)
      pw.Text('Nenhuma venda parecida encontrada.', style: _n(8))
    else
      _table(
        ['Data', 'Cliente', 'Medida', 'Espec.', 'Un.', 'Preço unit.', 'R\$/kg'],
        [
          for (final e in similar)
            [
              fmtDay(e['date']),
              _s(e['customer']),
              measure(e),
              _s(e['spec']).isEmpty ? '—' : _s(e['spec']),
              _s(e['unit']),
              e['unitPrice'] is num ? fmtMoney(e['unitPrice']) : '',
              e['pricePerKg'] is num ? fmtMoney(e['pricePerKg']) : '',
            ],
        ],
        flex: const [1, 2.6, 2.4, 1, 0.6, 1.2, 1.2],
        right: const {5, 6},
      ),
    pw.SizedBox(height: 14),
    pw.Text('Simulação interna${date.isEmpty ? '' : ' de ${fmtDay(date)}'}: não é proposta nem compromisso de preço.', style: _b(8)),
  ], header: (_) => _header('Simulação de preço', date.isEmpty ? '' : fmtDay(date), issuer));
}

/// App bar print button shared by the detail screens. It is busy while the PDF is built, so a second click does not print twice.
class PrintButton extends StatefulWidget {
  const PrintButton({super.key, required this.name, required this.builder, this.enabled = true, this.tooltip, this.doneKey, this.warning});

  /// When set, printing marks this paper as done (see PrintLog), so the flow does not ask about it again.
  final String? doneKey;
  final String name;
  final Future<Uint8List> Function() builder;
  final bool enabled;

  /// What the button says on hover; defaults to "Imprimir" plus the document name so several buttons in one bar tell themselves apart.
  final String? tooltip;

  /// A reason the paper is not final (see [quotePrintWarning]): the user is asked before it is printed anyway.
  final String? warning;

  @override
  State<PrintButton> createState() => _PrintButtonState();
}

class _PrintButtonState extends State<PrintButton> {
  bool _busy = false;

  Future<void> _print() async {
    final warning = widget.warning;
    if (warning != null) {
      final go = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded),
          title: const Text('Imprimir mesmo assim?'),
          content: Text('Este documento sai marcado: $warning.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Imprimir')),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      await printPdf(context, widget.name, widget.builder, doneKey: widget.doneKey);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: widget.tooltip ?? 'Imprimir ${widget.name}',
    icon: _busy ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.print_outlined),
    onPressed: widget.enabled && !_busy ? _print : null,
  );
}
