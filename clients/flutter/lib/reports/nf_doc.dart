import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../api.dart';
import '../entities.dart';
import '../screens/customers.dart' show fmtDocument;
import 'pdf_theme.dart';

// Dados do emitente conforme os modelos de NF-e. Ajustar quando o cadastro da empresa existir no sistema.
const _issuerName = 'Bst Ind Com de Produtos Metalurgicos Ltda';
const _issuerAddress = 'Rua Antonio da Silva Leite, 175 Anexo 2 - Vila Nova Parada';
const _issuerCity = 'CEP 02883-070 - Sao Paulo, Sp - Fone (11)4241-4436';
const _issuerIe = '124491149119';
const _issuerCnpj = '51.440.317/0001-80';

/// The company on top of the paper. The papers printed for NFs issued outside the system keep the BST data; the simulation takes it from the issuer register.
class _Issuer {
  const _Issuer({required this.name, required this.address, required this.city, required this.ie, required this.cnpj, this.brand = '', this.tagline = ''});

  final String name, address, city, ie, cnpj, brand, tagline;
}

const _bstIssuer = _Issuer(name: _issuerName, address: _issuerAddress, city: _issuerCity, ie: _issuerIe, cnpj: _issuerCnpj, brand: 'BSTTUBOS', tagline: 'PERFILADOS E TREFILADOS DE PRECISÃO');

/// The transporter block of the paper (the old system printed the issuer itself when the freight is ours).
class _Carrier {
  const _Carrier({required this.name, this.document = '', this.ie = '', this.address = '', this.city = '', this.uf = '', this.plate = '', this.mode = '0 - Rem. (CIF)'});

  final String name, document, ie, address, city, uf, plate, mode;
}

const _venda = 'VENDA DE MERCADORIA';
const _remessa = 'REMESSA PARA INDUSTRIALIZACAO';

String _s(Object? v) => v == null ? '' : '$v';
num _n(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;
String _money(num v) => fmtNum(v, 2);
String _qtd(num v, int d) => fmtNum(v, d);
String _date(DateTime d) => fmtDayOf(d);

/// Campos preenchidos pelo faturamento (a NF-e é emitida fora do sistema).
class NfFiscal {
  const NfFiscal({this.number = '', this.series = '001', this.accessKey = '', this.protocol = ''});

  final String number, series, accessKey, protocol;
}

class _Item {
  const _Item({required this.code, required this.description, required this.ncm, required this.cst, required this.cfop, required this.unit, required this.qty, required this.unitPrice, this.icms = 0, this.ipi = 0, this.totalValue, this.baseValue, this.icmsAmount, this.ipiAmount});

  final String code, description, ncm, cst, cfop, unit;
  final num qty, unitPrice, icms, ipi;

  /// Figures already calculated by the server (the simulation); without them they come from the rates (the papers of NFs issued outside).
  final num? totalValue, baseValue, icmsAmount, ipiAmount;

  num get total => totalValue ?? qty * unitPrice;
  num get base => baseValue ?? (cst == '000' ? total : 0);
  num get icmsValue => icmsAmount ?? (cst == '000' ? total * icms / 100 : 0);
  num get ipiValue => ipiAmount ?? (cst == '000' ? total * ipi / 100 : 0);
}

class _Party {
  const _Party({required this.name, this.document = '', this.ie = '', this.address = '', this.district = '', this.zip = '', this.city = '', this.uf = '', this.phone = ''});

  final String name, document, ie, address, district, zip, city, uf, phone;
}

class _Nf {
  const _Nf({required this.nature, required this.fiscal, required this.party, required this.items, required this.weight, required this.info, this.installments = const [], this.volumes = 1, this.issuer = _bstIssuer, this.carrier, this.species = 'VOLUME', this.netWeight, this.freight = 0, this.invoiceTotal, this.watermark = '', this.docTitle = ''});

  final String nature, info, species, watermark, docTitle;
  final _Issuer issuer;
  final _Carrier? carrier;
  final num? netWeight, invoiceTotal;
  final num freight;
  final NfFiscal fiscal;
  final _Party party;
  final List<_Item> items;
  final num weight;
  final int volumes;
  final List<(String, String, num)> installments;
}

/// Looks up data the NF paper needs. A record that no longer exists (404) prints blank; any other failure stops the print, since a
/// fiscal paper with silently missing customer, NCM or prices must never come out of the printer.
Future<Map<String, dynamic>?> _try(ApiClient api, String path) async {
  try {
    return await api.get(path) as Map<String, dynamic>;
  } on ApiException catch (e) {
    if (e.status == 404) return null;
    rethrow;
  }
}

Future<String> _ncm(ApiClient api, Object? productId) async => _s((await _try(api, '/api/products/$productId'))?['ncm']).replaceAll(RegExp(r'\D'), '');

/// DANFE de venda: itens e valores do pedido, impostos calculados pelos percentuais do item.
Future<Uint8List> buildSaleNfPdf(ApiClient api, Map<String, dynamic> delivery, NfFiscal fiscal) async {
  final order = await _try(api, '/api/sales/orders/${delivery['orderId']}') ?? {};
  final customer = await _try(api, '/api/customers/${delivery['customerId']}');
  final co = customer?['company'] as Map<String, dynamic>?;
  final ad = customer?['defaultAddress'] as Map<String, dynamic>?;
  String pick(String k) => _s(co?[k]).isNotEmpty ? _s(co?[k]) : _s(ad?[k]);
  final orderLines = {for (final l in (order['lines'] as List? ?? const []).cast<Map<String, dynamic>>()) l['id']: l};
  final items = <_Item>[];
  for (final l in (delivery['lines'] as List).cast<Map<String, dynamic>>()) {
    final ol = orderLines[l['orderLineId']] ?? const <String, dynamic>{};
    items.add(
      _Item(
        code: _s(l['productCode']),
        description: _s(l['description']),
        ncm: await _ncm(api, l['productId']),
        cst: '000',
        cfop: '5101',
        unit: _s(l['unit']),
        qty: _n(l['quantity']),
        unitPrice: _n(ol['unitPrice']),
        icms: _n(ol['icmsPercent']),
        ipi: _n(ol['ipiPercent']),
      ),
    );
  }
  final total = items.fold<num>(0, (a, i) => a + i.total + i.ipiValue);
  final terms = _s(order['paymentTermName']).isNotEmpty ? _s(order['paymentTermName']) : _s(order['customPaymentTerm']);
  final po = _s(order['customerPo']);
  final weight = _n(delivery['grossWeightKg']);
  final nf = _Nf(
    nature: _venda,
    fiscal: fiscal,
    party: _Party(
      name: _s(delivery['customerName']),
      document: fmtDocument(co?['document'] ?? ad?['document']),
      ie: pick('stateRegistration'),
      address: [pick('street'), pick('number')].where((e) => e.isNotEmpty).join(', ').isEmpty ? _s(delivery['addressText']) : [pick('street'), pick('number')].where((e) => e.isNotEmpty).join(', '),
      district: pick('district'),
      zip: pick('zipCode'),
      city: pick('city'),
      uf: pick('uf'),
      phone: pick('phone'),
    ),
    items: items,
    weight: weight,
    volumes: _n(delivery['packages']).toInt() == 0 ? 1 : _n(delivery['packages']).toInt(),
    installments: _installments(terms, total, DateTime.now()),
    info: 'MERCADORIA OBJETO DE COMERCIALIZACAO E/OU INDUSTRIALIZACAO PELO DESTINATARIO.${po.isEmpty ? '' : ' PEDIDO $po.'} ENTREGA ${_s(delivery['reference'])}.',
  );
  return _render(nf);
}

/// DANFE of the NF as the preview shows it (issuer, parties, items with their taxes, duplicatas, carrier, volumes, text), marked SIMULAÇÃO: to print and compare with what the old system issues.
Future<Uint8List> buildPreviewNfPdf(Map<String, dynamic> pv, {String number = ''}) async {
  final issuer = pv['issuer'] as Map<String, dynamic>;
  final rec = pv['recipient'] as Map<String, dynamic>;
  final tr = pv['transport'] as Map<String, dynamic>;
  final company = _s(pv['company']);
  // Title case as the old paper printed the issuer ("Bst Ind Com de Produtos Metalurgicos Ltda"): small words stay lower case.
  const small = {'de', 'da', 'do', 'das', 'dos', 'e'};
  String tc(String t) => t.isEmpty ? '' : t.split(' ').map((w) => w.isEmpty ? w : (small.contains(w.toLowerCase()) ? w.toLowerCase() : w[0].toUpperCase() + w.substring(1).toLowerCase())).join(' ');
  // The recipient is printed in capitals without accents, as the old system did.
  String caps(Object? v) => _s(v).toUpperCase().replaceAllMapped(RegExp('[ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ]'), (m) => 'AAAAAEEEEIIIIOOOOOUUUUC'['ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ'.indexOf(m[0]!)]);
  String phone(Object? v) {
    final d = _s(v).replaceAll(RegExp(r'\D'), '');
    return d.length == 10 ? '(${d.substring(0, 2)})${d.substring(2, 6)}-${d.substring(6)}' : (d.length == 11 ? '(${d.substring(0, 2)})${d.substring(2, 7)}-${d.substring(7)}' : d);
  }
  String zip(Object? v) {
    final d = _s(v).replaceAll(RegExp(r'\D'), '');
    return d.length == 8 ? '${d.substring(0, 5)}-${d.substring(5)}' : d;
  }
  String street(Map<String, dynamic> p) => [_s(p['street']), _s(p['number'])].where((e) => e.isNotEmpty).join(', ');
  final items = [
    for (final l in (pv['lines'] as List).cast<Map<String, dynamic>>())
      _Item(
        code: _s(l['code']),
        description: _s(l['description']),
        ncm: _s(l['ncm']),
        cst: '0${_s(l['icmsCst'])}',
        cfop: _s(pv['cfop']),
        unit: _s(l['unit']),
        qty: _n(l['quantity']),
        unitPrice: _n(l['unitPrice']),
        icms: _n(l['icmsPercent']),
        ipi: _n(l['ipiPercent']),
        totalValue: _n(l['total']),
        baseValue: _n(l['icmsValue']) > 0 ? _n(l['total']) : 0,
        icmsAmount: _n(l['icmsValue']),
        ipiAmount: _n(l['ipiValue']),
      ),
  ];
  final installments = [
    for (final i in (pv['installments'] as List).cast<Map<String, dynamic>>()) (fmtDay(i['dueDate']), _s(i['sequence']).padLeft(3, '0'), _n(i['amount'])),
  ];
  final pkgs = _n(tr['packages']).toInt();
  final nf = _Nf(
    nature: _s(pv['cfopDescription']).toUpperCase(),
    fiscal: NfFiscal(number: number.isEmpty ? _s(pv['nextNumber']) : number, series: _s(pv['series']).padLeft(3, '0'), protocol: ''),
    party: _Party(
      name: caps(rec['name']),
      document: fmtDocument(rec['document']),
      ie: _s(rec['stateRegistration']).replaceAll(RegExp(r'\D'), ''),
      address: street(rec).isEmpty ? caps(rec['address']) : caps(street(rec)),
      district: caps(rec['district']),
      zip: _s(rec['zipCode']),
      city: caps(rec['city']),
      uf: _s(rec['uf']),
      phone: phone(rec['phone']),
    ),
    items: items,
    weight: _n(tr['grossWeightKg']),
    netWeight: _n(tr['netWeightKg']),
    volumes: pkgs == 0 ? 1 : pkgs,
    species: _s(tr['species']).isEmpty ? 'VOLUME' : _s(tr['species']),
    installments: installments,
    info: _s(pv['additionalInfo']),
    freight: _n(pv['freightTotal']),
    invoiceTotal: _n(pv['invoiceTotal']),
    issuer: _Issuer(
      name: tc(_s(issuer['name'])),
      address: [street(issuer), _s(issuer['district'])].where((e) => e.isNotEmpty).map(tc).join(' - ').replaceAll(RegExp(r'\s+-\s*$'), ''),
      city: 'CEP ${zip(issuer['zipCode'])} - ${tc(_s(issuer['city']))}, ${tc(_s(issuer['uf']))}${phone(issuer['phone']).isEmpty ? '' : ' - Fone ${phone(issuer['phone'])}'}',
      ie: _s(issuer['stateRegistration']),
      cnpj: fmtDocument(issuer['document']),
      brand: company == 'BST' ? 'BSTTUBOS' : company,
      tagline: company == 'BST' ? 'PERFILADOS E TREFILADOS DE PRECISÃO' : '',
    ),
    carrier: _Carrier(
      name: _s(tr['carrier']),
      document: fmtDocument(tr['carrierDocument']),
      ie: _s(tr['carrierIe']),
      address: _s(tr['carrierAddress']),
      city: _s(tr['carrierCity']),
      uf: _s(tr['carrierUf']),
      plate: _s(tr['vehiclePlate']),
      mode: _n(tr['freightMode']) == 0 ? '0 - Rem. (CIF)' : '1 - Dest. (FOB)',
    ),
    watermark: 'SIMULAÇÃO — SEM VALOR FISCAL',
    docTitle: 'Simulação NF ${_s(pv['nextNumber'])}',
  );
  return _render(nf);
}

/// DANFE de remessa para industrialização (ex.: recozimento): sem destaque de impostos, CFOP 5901, CST 050.
Future<Uint8List> buildOutsideNfPdf(ApiClient api, Map<String, dynamic> shipment, NfFiscal fiscal) async {
  final order = await _try(api, '/api/production/orders/${shipment['orderId']}') ?? {};
  final ops = (order['operations'] as List? ?? const []).cast<Map<String, dynamic>>();
  final op = ops.firstWhere((o) => o['sequence'] == shipment['operationSequence'], orElse: () => const {});
  final addresses = await api.get('/api/suppliers/${shipment['supplierId']}/addresses').then((r) => (r as List).cast<Map<String, dynamic>>()).catchError((_) => <Map<String, dynamic>>[]);
  final a = addresses.isEmpty ? const <String, dynamic>{} : addresses.first;
  final unit = _s(order['productUnit']).isEmpty ? 'KG' : _s(order['productUnit']).toUpperCase();
  final qty = _n(shipment['quantity']);
  final opText = _s(op['description']).isEmpty ? 'BENEFICIAMENTO' : _s(op['description']).toUpperCase();
  final price = qty == 0 ? 0 : _n(shipment['serviceValue']) / qty;
  final nf = _Nf(
    nature: _remessa,
    fiscal: fiscal,
    party: _Party(
      name: _s(shipment['supplierName']),
      document: fmtDocument(a['document']),
      ie: _s(a['stateRegistration']),
      address: [_s(a['street']), _s(a['number'])].where((e) => e.isNotEmpty).join(', '),
      district: _s(a['district']),
      zip: _s(a['zipCode']),
      city: _s(a['city']),
      uf: _s(a['uf']),
      phone: _s(a['phone']),
    ),
    items: [
      _Item(
        code: _s(order['productCode']),
        description: '$opText - APLICADO NO ${_s(order['productName']).toUpperCase()} - OF ${_s(order['reference'])}',
        ncm: await _ncm(api, order['productId']),
        cst: '050',
        cfop: '5901',
        unit: unit,
        qty: qty,
        unitPrice: price,
      ),
    ],
    weight: unit == 'KG' ? qty : 0,
    info:
        'MATERIAL DE NOSSA PROPRIEDADE QUE SEGUE PARA INDUSTRIALIZACAO DEVENDO RETORNAR PARA NOVA INDUSTRIALIZACAO E/OU COMERCIALIZACAO. IPI - SUSPENSO ART. 43, INC.VI E VII DEC.7212/10. ICMS - SUSPENSO ART. 402 DO DECRETO 45490/00.${_s(shipment['notes']).isEmpty ? '' : ' ${_s(shipment['notes'])}'}',
  );
  return _render(nf);
}

/// "30/60/90" ou "28 dias" → parcelas iguais a partir da data de emissão.
List<(String, String, num)> _installments(String terms, num total, DateTime from) {
  final days = RegExp(r'\d+').allMatches(terms).map((m) => int.parse(m.group(0)!)).where((d) => d > 0 && d < 400).toList();
  if (days.isEmpty || total <= 0) return const [];
  final each = (total / days.length * 100).floor() / 100;
  return [
    for (var i = 0; i < days.length; i++) (_date(from.add(Duration(days: days[i]))), (i + 1).toString().padLeft(3, '0'), i == 0 ? total - each * (days.length - 1) : each),
  ];
}

const _line = PdfColors.black;

pw.TextStyle _lbl() => const pw.TextStyle(fontSize: 5.5, fontStyle: pw.FontStyle.italic, color: PdfColors.grey800);
pw.TextStyle _val([double size = 8, bool bold = false]) => pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : null);

pw.Widget _cell(String label, String value, {int flex = 1, bool right = false, bool bold = false, double size = 8, PdfColor? fill}) => pw.Expanded(
  flex: flex,
  child: pw.Container(
    padding: const pw.EdgeInsets.fromLTRB(3, 1, 3, 2),
    decoration: pw.BoxDecoration(color: fill, border: pw.Border.all(color: _line, width: 0.4)),
    child: pw.Column(
      crossAxisAlignment: right ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.start,
      children: [
        pw.Text(label, style: _lbl()),
        pw.Text(value, style: _val(size, bold), maxLines: 2),
      ],
    ),
  ),
);

pw.Widget _row(List<pw.Widget> cells, {double? height}) => pw.SizedBox(height: height ?? 24, child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: cells));

pw.Widget _title(String t) => pw.Padding(
  padding: const pw.EdgeInsets.only(top: 3, bottom: 1),
  child: pw.Text(t, style: const pw.TextStyle(fontSize: 7, fontWeight: pw.FontWeight.bold)),
);

Future<Uint8List> _render(_Nf nf) async {
  final doc = pw.Document(
    title: nf.docTitle.isEmpty ? 'NF ${nf.fiscal.number}' : nf.docTitle,
    theme: await pdfTheme(italicAsRegular: true),
  );
  final now = DateTime.now();
  final f = nf.fiscal;
  final numberText = f.number.isEmpty ? '' : f.number.replaceAll(RegExp(r'\D'), '').padLeft(9, '0').replaceAllMapped(RegExp(r'(\d{3})(\d{3})(\d{3})'), (m) => '${m[1]}.${m[2]}.${m[3]}');
  final products = nf.items.fold<num>(0, (a, i) => a + i.total);
  final ipi = nf.items.fold<num>(0, (a, i) => a + i.ipiValue);
  final base = nf.items.fold<num>(0, (a, i) => a + i.base);
  final iss = nf.issuer;
  final car = nf.carrier ?? const _Carrier(name: 'BST', document: _issuerCnpj, ie: _issuerIe, address: 'RUA ANTONIO DA SILVA LEITE,175 ANEXO 2', city: 'SAO PAULO', uf: 'SP');
  final icms = nf.items.fold<num>(0, (a, i) => a + i.icmsValue);
  final taxed = base > 0;
  final p = nf.party;

  const w = <double>[48, 150, 38, 18, 20, 18, 36, 32, 40, 38, 36, 26, 24];
  pw.Widget head(String t, double width) => pw.Container(
    width: width,
    padding: const pw.EdgeInsets.all(2),
    decoration: pw.BoxDecoration(color: PdfColors.grey300, border: pw.Border.all(width: 0.4)),
    child: pw.Text(t, style: const pw.TextStyle(fontSize: 5.5, fontWeight: pw.FontWeight.bold), textAlign: pw.TextAlign.center),
  );
  pw.Widget item(String t, double width, {bool right = false}) => pw.Container(
    width: width,
    padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 1),
    child: pw.Text(t, style: _val(6.5), textAlign: right ? pw.TextAlign.right : pw.TextAlign.left),
  );
  final heads = ['CÓD. PRODUTO', 'DESCRIÇÃO DOS PRODUTOS / SERVIÇOS', 'NCM', 'CST', 'CFOP', 'UNID', 'QUANTIDADE', 'VALOR UNIT.', 'VALOR TOTAL', 'B. CALC. ICMS', 'VALOR ICMS', 'ICMS %', 'IPI %'];

  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(22, 20, 22, 20),
      build: (_) => _watermarked(nf.watermark, pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          _row([
            pw.Expanded(
              flex: 5,
              child: pw.Container(
                padding: const pw.EdgeInsets.all(3),
                decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
                child: pw.Text('Recebemos de ${iss.name} os produtos constantes na nota fiscal indicada ao lado', style: _val(8)),
              ),
            ),
            pw.Container(
              width: 110,
              padding: const pw.EdgeInsets.all(3),
              decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('NF-e', style: _val(11, true)),
                  pw.Text('Nº $numberText', style: _val(8, true)),
                  pw.Text('SÉRIE ${f.series}', style: _val(8, true)),
                ],
              ),
            ),
          ], height: 40),
          _row([_cell('DATA DE RECEBIMENTO', '', flex: 2), _cell('IDENTIFICAÇÃO E ASSINATURA DO RECEBEDOR', '', flex: 5)]),
          pw.SizedBox(height: 6),
          _row([
            pw.Expanded(
              flex: 5,
              child: pw.Container(
                padding: const pw.EdgeInsets.all(4),
                decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    if (iss.brand.isNotEmpty) pw.Text(iss.brand, style: _val(20, true)),
                    if (iss.tagline.isNotEmpty) pw.Text(iss.tagline, style: _val(6, true)),
                    pw.SizedBox(height: 4),
                    pw.Text(iss.name, style: _val(9, true)),
                    pw.Text(iss.address, style: _val(6.5)),
                    pw.Text(iss.city, style: _val(6.5)),
                  ],
                ),
              ),
            ),
            pw.Container(
              width: 100,
              padding: const pw.EdgeInsets.all(3),
              decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
              child: pw.Column(
                children: [
                  pw.Text('DANFE', style: _val(11, true)),
                  pw.Text('Documento Auxiliar de Nota Fiscal Eletrônica', style: _val(6), textAlign: pw.TextAlign.center),
                  pw.SizedBox(height: 3),
                  pw.Text('0 - ENTRADA\n1 - SAÍDA   [ 1 ]', style: _val(6.5)),
                  pw.Spacer(),
                  pw.Text('Nº $numberText', style: _val(8, true)),
                  pw.Text('SÉRIE ${f.series}', style: _val(8, true)),
                  pw.Text('FOLHA 001/001', style: _val(8, true)),
                ],
              ),
            ),
            pw.Expanded(
              flex: 6,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  pw.Container(
                    height: 38,
                    padding: const pw.EdgeInsets.all(3),
                    decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
                    child: f.accessKey.replaceAll(' ', '').isEmpty ? pw.SizedBox() : pw.BarcodeWidget(barcode: pw.Barcode.code128(), data: f.accessKey.replaceAll(' ', ''), drawText: false),
                  ),
                  pw.Expanded(child: _cellBox('CHAVE DE ACESSO', f.accessKey, bold: true)),
                  pw.Container(
                    height: 28,
                    padding: const pw.EdgeInsets.all(3),
                    decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
                    child: pw.Text('Consulta de Autenticidade no portal nacional da NF-e\nwww.nfe.fazenda.gov.br/portal ou no site da Sefaz Autorizadora', style: _val(6.5)),
                  ),
                ],
              ),
            ),
          ], height: 104),
          _row([_cell('NATUREZA DA OPERAÇÃO', nf.nature, flex: 5, size: 10), _cell('PROTOCOLO DE AUTORIZAÇÃO DE USO', f.protocol.isEmpty ? '' : '${f.protocol}  ${_date(now)}', flex: 5, bold: true)]),
          _row([_cell('INSCRIÇÃO ESTADUAL', iss.ie, flex: 3), _cell('INSCR. DO SUBST. TRIBUT.', '', flex: 3), _cell('CNPJ', iss.cnpj, flex: 4, bold: true)]),
          _title('DESTINATÁRIO / REMETENTE'),
          _row([_cell('NOME / RAZÃO SOCIAL', p.name, flex: 6, size: 9), _cell('CNPJ / CPF', p.document, flex: 3), _cell('DATA DE EMISSÃO', _date(now), flex: 2, bold: true)]),
          _row([_cell('ENDEREÇO', p.address, flex: 6), _cell('BAIRRO / DISTRITO', p.district, flex: 3), _cell('CEP', p.zip, flex: 2), _cell('DATA DE ENTRADA / SAÍDA', _date(now), flex: 2)]),
          _row([
            _cell('MUNICÍPIO', p.city, flex: 5),
            _cell('FONE / FAX', p.phone, flex: 3),
            _cell('UF', p.uf, flex: 1),
            _cell('INSCRIÇÃO ESTADUAL', p.ie, flex: 3),
            _cell('HORA DA SAÍDA', '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}', flex: 2),
          ]),
          _title('FATURA / DUPLICATA'),
          pw.Container(
            height: 44,
            padding: const pw.EdgeInsets.all(3),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
            child: pw.Wrap(
              spacing: 18,
              children: [
                for (final (d, n, v) in nf.installments)
                  pw.SizedBox(
                    width: 150,
                    child: pw.Row(children: [pw.Expanded(child: pw.Text(d, style: _val(8))), pw.Expanded(child: pw.Text(n, style: _val(8))), pw.Text(_money(v), style: _val(8))]),
                  ),
              ],
            ),
          ),
          _title('CÁLCULO DO IMPOSTO'),
          _row([
            _cell('BASE DE CÁLCULO DO ICMS', taxed ? _money(base) : '', right: true),
            _cell('VALOR DO ICMS', taxed ? _money(icms) : '', right: true),
            _cell('BASE DE CÁLCULO DO ICMS ST', '', right: true),
            _cell('VALOR DO ICMS SUBSTITUIÇÃO', '', right: true),
            _cell('VALOR TOTAL DOS PRODUTOS', _money(products), right: true),
          ]),
          _row([
            _cell('VALOR DO FRETE', nf.freight > 0 ? _money(nf.freight) : '', right: true),
            _cell('VALOR DO SEGURO', '', right: true),
            _cell('DESCONTO', '', right: true),
            _cell('OUTRAS DESPESAS ACESSÓRIAS', '', right: true),
            _cell('VALOR TOTAL DO IPI', ipi > 0 ? _money(ipi) : '', right: true),
            _cell('VALOR TOTAL DA NOTA', _money(nf.invoiceTotal ?? products + ipi), right: true, bold: true, size: 10, fill: PdfColors.grey300),
          ]),
          _title('TRANSPORTADOR / VOLUMES TRANSPORTADOS'),
          _row([
            _cell('NOME / RAZÃO SOCIAL', car.name, flex: 5),
            _cell('FRETE POR CONTA', car.mode, flex: 2),
            _cell('CÓDIGO ANTT', '', flex: 2),
            _cell('PLACA DO VEÍCULO', car.plate, flex: 2),
            _cell('UF', '', flex: 1),
            _cell('CNPJ / CPF', car.document, flex: 3),
          ]),
          _row([
            _cell('ENDEREÇO', car.address, flex: 6),
            _cell('MUNICÍPIO', car.city, flex: 3),
            _cell('UF', car.uf, flex: 1),
            _cell('INSCRIÇÃO ESTADUAL', car.ie, flex: 3),
          ]),
          _row([
            _cell('QUANTIDADE', '${nf.volumes}', flex: 2, right: true),
            _cell('ESPÉCIE', nf.species, flex: 2),
            _cell('MARCA', '', flex: 2),
            _cell('NÚMERO', '', flex: 3),
            _cell('PESO BRUTO', nf.weight > 0 ? _qtd(nf.weight, 3) : '', flex: 3, right: true),
            _cell('PESO LÍQUIDO', (nf.netWeight ?? nf.weight) > 0 ? _qtd(nf.netWeight ?? nf.weight, 3) : '', flex: 3, right: true),
          ], height: 28),
          _title('DADOS DOS PRODUTOS / SERVIÇOS'),
          pw.Container(
            height: 290,
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Row(children: [for (var i = 0; i < heads.length; i++) head(heads[i], w[i])]),
                for (final i in nf.items)
                  pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      item(i.code, w[0]),
                      item(i.description, w[1]),
                      item(i.ncm, w[2]),
                      item(i.cst, w[3]),
                      item(i.cfop, w[4]),
                      item(i.unit, w[5]),
                      item(_qtd(i.qty, 4), w[6], right: true),
                      item(i.unitPrice == 0 ? '' : _money(i.unitPrice), w[7], right: true),
                      item(i.total == 0 ? '' : _money(i.total), w[8], right: true),
                      item(i.base > 0 ? _money(i.base) : '', w[9], right: true),
                      item(i.base > 0 ? _money(i.icmsValue) : '', w[10], right: true),
                      item(i.base > 0 ? _money(i.icms) : '', w[11], right: true),
                      item(i.ipiValue > 0 ? _money(i.ipi) : '', w[12], right: true),
                    ],
                  ),
              ],
            ),
          ),
          _title('CÁLCULO DO ISSQN'),
          _row([_cell('INSCRIÇÃO MUNICIPAL', '', flex: 3), _cell('VALOR TOTAL DOS SERVIÇOS', '', flex: 3, right: true), _cell('BASE DE CÁLCULO DO ISSQN', '', flex: 3, right: true), _cell('VALOR DO ISSQN', '', flex: 3, right: true)]),
          _title('DADOS ADICIONAIS'),
          pw.Expanded(
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Expanded(flex: 6, child: _cellBox('INFORMAÇÕES COMPLEMENTARES', nf.info, size: 7.5)),
                pw.Expanded(flex: 4, child: _cellBox('RESERVADO AO FISCO', '')),
              ],
            ),
          ),
        ],
      )),
    ),
  );
  return savePdf(doc);
}

/// A faint diagonal text over the page ("SIMULAÇÃO"), so a printed preview can never be taken for a real NF.
pw.Widget _watermarked(String text, pw.Widget page) => text.isEmpty
    ? page
    : pw.Stack(
        children: [
          page,
          pw.Positioned.fill(
            child: pw.Center(
              child: pw.Transform.rotate(angle: 0.6, child: pw.Opacity(opacity: 0.16, child: pw.Text(text, style: const pw.TextStyle(fontSize: 54, fontWeight: pw.FontWeight.bold, color: PdfColors.red800)))),
            ),
          ),
        ],
      );

pw.Widget _cellBox(String label, String value, {bool bold = false, double size = 8}) => pw.Container(
  padding: const pw.EdgeInsets.fromLTRB(3, 1, 3, 2),
  decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.4)),
  child: pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.start,
    children: [
      pw.Text(label, style: _lbl()),
      pw.Text(value, style: _val(size, bold)),
    ],
  ),
);

/// Pede os dados da NF-e já emitida (número, chave e protocolo) e devolve null se cancelado.
Future<NfFiscal?> askNfFiscal(BuildContext context, {String number = ''}) => showDialog<NfFiscal>(context: context, builder: (_) => _NfFiscalDialog(number: number));

/// The dialog owns its four controllers and disposes them with itself (after its closing animation), so none is left behind per print.
class _NfFiscalDialog extends StatefulWidget {
  const _NfFiscalDialog({required this.number});

  final String number;

  @override
  State<_NfFiscalDialog> createState() => _NfFiscalDialogState();
}

class _NfFiscalDialogState extends State<_NfFiscalDialog> {
  late final _n = TextEditingController(text: widget.number);
  final _s = TextEditingController(text: '001');
  final _k = TextEditingController();
  final _p = TextEditingController();

  @override
  void dispose() {
    _n.dispose();
    _s.dispose();
    _k.dispose();
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Imprimir NF'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: _n, decoration: const InputDecoration(labelText: 'Nº da NF')),
            TextField(controller: _s, decoration: const InputDecoration(labelText: 'Série')),
            TextField(controller: _k, decoration: const InputDecoration(labelText: 'Chave de acesso (opcional)')),
            TextField(controller: _p, decoration: const InputDecoration(labelText: 'Protocolo de autorização (opcional)')),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
      FilledButton(onPressed: () => Navigator.pop(context, NfFiscal(number: _n.text.trim(), series: _s.text.trim(), accessKey: _k.text.trim(), protocol: _p.text.trim())), child: const Text('Imprimir')),
    ],
  );
}

/// Pergunta os dados fiscais, monta o PDF e abre a impressão.
/// Responde se o papel chegou a ser impresso (false: o usuário cancelou ou deu erro).
Future<bool> printNf(BuildContext context, {required String name, String number = '', required Future<Uint8List> Function(NfFiscal) build}) async {
  final f = await askNfFiscal(context, number: number);
  if (f == null || !context.mounted) return false;
  try {
    final bytes = await build(f);
    return await Printing.layoutPdf(name: name, onLayout: (_) async => bytes, format: PdfPageFormat.a4);
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Falha ao imprimir: ${friendlyError(e)}')));
    return false;
  }
}
