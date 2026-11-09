import 'dart:convert';
import 'dart:typed_data';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/screens/fiscal_import.dart';
import 'package:ebt_engenharia/screens/sales_common.dart';
import 'package:ebt_engenharia/screens/sales_orders.dart';
import 'package:ebt_engenharia/screens/sales_quotes.dart';
import 'package:ebt_engenharia/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'role_permissions.dart';
import 'sales_more_support.dart';

Map<String, dynamic> _party(String name) => {'name': name, 'document': '26133636000103', 'stateRegistration': '111', 'address': 'Av X, 10 - Centro', 'city': 'Embu', 'uf': 'SP', 'zipCode': '06800000', 'cityIbgeCode': '3515004'};

Map<String, dynamic> _preview({bool ready = true, List<Map<String, dynamic>> problems = const []}) => {
  'fiscalEnabled': false,
  'simulated': true,
  'environment': 'Homologation',
  'series': 1,
  'nextNumber': 2581,
  'cfop': '5101',
  'cfopDescription': 'VENDA DE MERCADORIA',
  'issuer': _party('EBT IND COM'),
  'recipient': _party('BTS Tubos'),
  'lines': [
    {
      'sequence': 10,
      'code': 'TB-25',
      'description': 'Tubo 25,4 x 1,5',
      'ncm': '73063010',
      'unit': 'PC',
      'quantity': 10,
      'unitPrice': 100,
      'total': 1000,
      'priceSource': 'Pedido',
      'icmsCst': '00',
      'icmsPercent': 18,
      'icmsValue': 180,
      'ipiCst': '50',
      'ipiPercent': 3.25,
      'ipiValue': 32.5,
      'pisValue': 6.5,
      'cofinsValue': 30,
      'taxSource': 'Padrão do CFOP 5101',
    },
  ],
  'productsTotal': 1000,
  'freightTotal': 0,
  'icmsBase': 1000,
  'icmsTotal': 180,
  'ipiTotal': 32.5,
  'pisTotal': 6.5,
  'cofinsTotal': 30,
  'invoiceTotal': 1032.5,
  'installments': [
    {'sequence': 1, 'dueDate': '2026-12-07', 'amount': 1032.5},
  ],
  'transport': {'mode': 'Por conta do emitente (CIF)', 'carrier': null, 'netWeightKg': 12.5},
  'additionalInfo': 'PV 9 | Pedido cliente PO-9',
  'problems': problems,
  'ready': ready,
};

http.Response _json(Object? body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json; charset=utf-8'});

void main() {
  testWidgets('the order in production has a Nota Fiscal step and a button that opens the simulation', (tester) async {
    final f = MoreFake()..order['status'] = 'Released';
    f.overrides['GET /api/fiscal/preview/order/9'] = (r) => _json(_preview());
    await pumpMore(tester, f, (s) => SalesOrderScreen(session: s, id: 9), size: const Size(1400, 2200));
    expect(find.text('Nota Fiscal'), findsWidgets); // the step in the path and the button
    await tapKey(tester, 'order-invoice');
    expect(f.called('GET', '/api/fiscal/preview/order/9'), isTrue);
    expect(find.byKey(const ValueKey('invoice-simulation')), findsOneWidget);
    expect(find.byKey(const ValueKey('invoice-ready')), findsOneWidget);
    expect(find.textContaining('TB-25'), findsWidgets);
    expect(find.text('Duplicatas'), findsOneWidget);
    expect(find.byKey(const ValueKey('invoice-problems')), findsNothing);
  });

  testWidgets('the simulation lists what is missing and where to fix it', (tester) async {
    final f = MoreFake()..order['status'] = 'Released';
    f.overrides['GET /api/fiscal/preview/order/9'] = (r) => _json(
      _preview(
        ready: false,
        problems: [
          {'area': 'Emitente', 'message': 'Dados do emitente incompletos: CNPJ.', 'fix': 'Configurações > Fiscal > Dados do emitente', 'blocking': true},
          {'area': 'SEFAZ', 'message': 'Sem certificado digital A1: a NF é só simulada.', 'fix': 'Configurações > Fiscal > Certificado digital', 'blocking': false},
        ],
      ),
    );
    await pumpMore(tester, f, (s) => SalesOrderScreen(session: s, id: 9), size: const Size(1400, 2200));
    await tapKey(tester, 'order-invoice');
    expect(find.byKey(const ValueKey('invoice-blocked')), findsOneWidget);
    expect(find.text('Falta 1 item para emitir'), findsOneWidget);
    expect(find.textContaining('Emitente: Dados do emitente incompletos'), findsOneWidget);
    expect(find.textContaining('Configurações > Fiscal > Dados do emitente'), findsOneWidget);
    expect(find.textContaining('SEFAZ: Sem certificado'), findsOneWidget);
  });

  testWidgets('the unit price of an item is required', (tester) async {
    final f = MoreFake();
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true));
    await tapKey(tester, 'quote-customer');
    await tester.tap(find.text('BTS Tubos').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'add-line');
    await tester.tap(find.text('TB-25 · Tubo 25,4 x 1,5').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-quantity')), '10');
    await tester.enterText(find.byKey(const ValueKey('field-unitPrice')), '');
    await tester.tap(find.widgetWithText(FilledButton, 'Adicionar item').last);
    await tester.pumpAndSettle();
    expect(find.text('Obrigatório'), findsWidgets); // the dialog stays open
    await tester.enterText(find.byKey(const ValueKey('field-unitPrice')), '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Adicionar item').last);
    await tester.pumpAndSettle();
    expect(find.text('Deve ser maior que zero'), findsOneWidget);
  });

  testWidgets('an item without a lead time gets 7 working days', (tester) async {
    final f = MoreFake();
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true));
    await tapKey(tester, 'quote-customer');
    await tester.tap(find.text('BTS Tubos').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'add-line');
    await tester.tap(find.text('TB-25 · Tubo 25,4 x 1,5').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-quantity')), '10');
    expect(tester.widget<TextField>(find.byKey(const ValueKey('field-leadTimeDays'))).controller!.text, '7'); // prefilled
    await tester.enterText(find.byKey(const ValueKey('field-leadTimeDays')), ''); // cleared: the fallback still applies
    await tester.tap(find.widgetWithText(FilledButton, 'Adicionar item').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'quote-save');
    final line = (f.body(f.last('POST', '/api/sales/orders'))['lines'] as List).single as Map<String, dynamic>;
    expect(line['leadTimeDays'], 7);
    expect(line['deliveryDate'], isNotNull);
  });

  testWidgets('the order path has the Nota Fiscal step between the production order and the certificate', (tester) async {
    expect(flowSteps.map((s) => s.label).toList().sublist(5, 8), ['Ordem de Fabricação', 'Nota Fiscal', 'Certificado']);
    expect(orderPath('Released', ready: true, certified: false).$1, 7); // certificate is the current step
    expect(orderPath('Released', ready: true, certified: true).$1, 8); // delivery
    expect(deliveryPath('Shipped').$1, 8);
  });

  testWidgets('fiscal data import: previews the file, then imports it after the confirmation', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final oldPicker = fiscalDataFilePicker;
    fiscalDataFilePicker = () async => (name: 'fiscal-data.json', bytes: Uint8List.fromList(utf8.encode('{}')));
    addTearDown(() => fiscalDataFilePicker = oldPicker);
    final log = <http.Request>[];
    final client = MockClient((r) async {
      log.add(r);
      if (r.url.path == '/api/fiscal/legacy-import/summary') return _json({'issuerFilled': false, 'cfops': 8, 'carriers': 0, 'taxRules': 0, 'monthlyPrices': 0, 'nextNumber': 2581});
      return _json({
        'applied': r.url.queryParameters['apply'] == 'true',
        'source': 'EBT',
        'sections': [
          {'section': 'issuer', 'title': 'Dados do emitente', 'read': 1, 'added': 0, 'updated': 1, 'unchanged': 0, 'skipped': 0, 'notes': ['A emissão continua desligada: ligue em Configurações > Fiscal quando o certificado A1 estiver pronto.']},
          {'section': 'carriers', 'title': 'Transportadoras', 'read': 5, 'added': 5, 'updated': 0, 'unchanged': 0, 'skipped': 0, 'notes': <String>[]},
          {'section': 'taxRules', 'title': 'Impostos por produto e cliente', 'read': 189, 'added': 180, 'updated': 0, 'unchanged': 0, 'skipped': 9, 'notes': ['9 ignoradas: cliente não cadastrado']},
        ],
      });
    });
    final session = Session(api: ApiClient(baseUrl: 'http://api.test', client: client, token: 'tok'))
      ..username = 'admin'
      ..role = 'Admin'
      ..permissions = rolePermissions['Admin']!;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('pt', 'BR'),
        supportedLocales: const [Locale('pt', 'BR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Builder(builder: (c) => TextButton(onPressed: () => showFiscalImportDialog(c, session), child: const Text('abrir'))),
      ),
    );
    await tester.tap(find.text('abrir'));
    await tester.pumpAndSettle();
    expect(find.textContaining('emitente vazio'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fiscal-import-choose')));
    await tester.pumpAndSettle();
    expect(log.last.url.queryParameters['apply'], 'false'); // the first call only previews
    expect(find.textContaining('Prévia: nada foi salvo ainda'), findsOneWidget);
    expect(find.textContaining('Transportadoras: 5 lidos · 5 novos'), findsOneWidget);
    expect(find.textContaining('9 ignoradas: cliente não cadastrado'), findsOneWidget);
    expect(find.text('Importar 186 registros'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fiscal-import-apply')));
    await tester.pumpAndSettle();
    expect(log.where((r) => r.url.path == '/api/fiscal/legacy-import').last.url.queryParameters['apply'], 'true');
    expect(find.text('Dados importados.'), findsOneWidget);
  });
}
