import 'dart:convert';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/entities.dart';
import 'package:ebt_engenharia/reports/print_docs.dart';
import 'package:ebt_engenharia/screens/customer_print.dart';
import 'package:ebt_engenharia/widgets/record_list.dart';
import 'package:ebt_engenharia/widgets/record_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pdf/pdf.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _customer(int i) => {
  'id': i,
  'name': 'CLIENTE $i LTDA',
  'tradeName': 'Fantasia $i',
  'clientCode': '$i',
  'active': i % 5 != 0,
  'company': {
    'document': '26133636000103',
    'stateRegistration': '111222333444',
    'icmsContributor': true,
    'street': 'Av. das Nações',
    'number': '$i',
    'city': 'São Paulo',
    'uf': 'SP',
    'zipCode': '01000000',
    'contact': 'Maria',
    'phone': '1133334444',
    'email': 'compras$i@cliente.test',
    'paymentTermName': '28 dias',
    'creditLimit': 50000,
    'ipiPercent': 3.25,
    'icmsPercent': 18,
    'taxNote': 'IPI 5% em 2019, 3,25% desde 2022',
  },
};

ApiClient _api({int total = 130}) {
  final client = MockClient((r) async {
    if (r.url.path == '/api/customers') {
      final skip = int.parse(r.url.queryParameters['skip'] ?? '0');
      final take = int.parse(r.url.queryParameters['take'] ?? '50');
      final q = r.url.queryParameters['q'] ?? '';
      final all = [for (var i = 1; i <= total; i++) _customer(i)].where((c) => q.isEmpty || '${c['name']}'.contains(q)).toList();
      return _json({'items': all.skip(skip).take(take).toList(), 'total': all.length, 'skip': skip, 'take': take});
    }
    if (r.url.path.endsWith('/addresses')) {
      return _json([
        {'street': 'Rua da Entrega', 'number': '5', 'city': 'Embu', 'uf': 'SP', 'buyer': 'João', 'phone': '1144445555'},
      ]);
    }
    return _json({}, 404);
  });
  return ApiClient(baseUrl: 'http://api.test', client: client, token: 'tok');
}

/// Width and height of the first page: the MediaBox of the saved document.
({double w, double h}) _firstPage(List<int> bytes) {
  final m = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]').firstMatch(latin1.decode(bytes, allowInvalid: true));
  expect(m, isNotNull, reason: 'no MediaBox in the PDF');
  return (w: double.parse(m!.group(1)!), h: double.parse(m.group(2)!));
}

int _pages(List<int> bytes) => RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes, allowInvalid: true)).length;

void main() {
  group('customer PDFs', () {
    test('one customer: a single portrait page', () async {
      final api = _api();
      final bytes = await buildCustomersPdf(api, [_customer(7)]);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      final p = _firstPage(bytes);
      expect(p.h, greaterThan(p.w), reason: 'portrait');
      expect(_pages(bytes), 1);
    });

    test('several customers: a landscape list that spills over pages, in order', () async {
      final api = _api();
      final rows = [for (var i = 1; i <= 120; i++) _customer(i)];
      final bytes = await buildCustomersPdf(api, rows, filters: customerPrintFilters(search: 'CLIENTE', active: 'true'));
      final p = _firstPage(bytes);
      expect(p.w, greaterThan(p.h), reason: 'landscape');
      expect(_pages(bytes), greaterThan(1));
      // Two is already a list, not a sheet.
      final two = await buildCustomersPdf(api, rows.take(2).toList());
      final p2 = _firstPage(two);
      expect(p2.w, greaterThan(p2.h));
      expect(_pages(two), 1);
    });

    test('a list copes with customers that have no company data', () async {
      final bytes = await buildCustomersListPdf(_api(), [
        {'id': 1, 'name': 'SEM DADOS'},
        {'id': 2, 'name': 'OUTRO', 'active': true, 'company': <String, dynamic>{}},
      ]);
      expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    });

    test('print format follows the selection size; the filter lines say what narrowed the list', () {
      expect(customerPrintFormat(1), PdfPageFormat.a4);
      expect(customerPrintFormat(2), PdfPageFormat.a4.landscape);
      expect(customerPrintFilters(search: ' aço ', active: 'false'), ['Busca: aço', 'Situação: inativos']);
      expect(customerPrintFilters(), isEmpty);
    });
  });

  group('RecordSelection', () {
    test('keeps whole rows by id, across additions and removals', () {
      final s = RecordSelection();
      var ticks = 0;
      s.addListener(() => ticks++);
      s.set(_customer(1), true);
      s.set(_customer(1), true); // no change, no notification
      s.toggle(_customer(2));
      expect(s.count, 2);
      expect(s.contains({'id': 2}), isTrue);
      s.set(_customer(1), false);
      expect(s.rows.map((r) => r['id']), [2]);
      s.clear();
      expect(s.isEmpty, isTrue);
      expect(ticks, 4);
    });
  });

  group('selection on the list', () {
    Future<void> pump(WidgetTester tester, RecordSelection sel, ApiClient api, {double width = 1400}) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('pt', 'BR'),
          supportedLocales: const [Locale('pt', 'BR')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: RecordList(
              api: api,
              path: '/api/customers',
              pageSize: 20,
              columns: [col('Cliente', 'name')],
              selection: sel,
              selectionActions: (ctx, s) => [Text('ações ${s.count}', key: const ValueKey('actions'))],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('ticking rows counts them and shows the actions; select-all takes every page, not only the visible one', (tester) async {
      final sel = RecordSelection();
      await pump(tester, sel, _api());
      expect(find.byKey(const ValueKey('selection-count')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('selection-count'))).data, 'Selecionar todos (130)');
      expect(find.byKey(const ValueKey('actions')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('select-1')));
      await tester.tap(find.byKey(const ValueKey('select-2')));
      await tester.pump();
      expect(sel.count, 2);
      expect(tester.widget<Text>(find.byKey(const ValueKey('selection-count'))).data, '2 selecionados');
      expect(find.byKey(const ValueKey('actions')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('select-all')));
      await tester.pumpAndSettle();
      expect(sel.count, 130);
      expect(tester.widget<Text>(find.byKey(const ValueKey('selection-count'))).data, 'Todos os 130 selecionados');

      // Ticked again: everything is cleared.
      await tester.tap(find.byKey(const ValueKey('select-all')));
      await tester.pumpAndSettle();
      expect(sel.isEmpty, isTrue);
    });

    testWidgets('select-all follows the search: only the customers that match', (tester) async {
      final sel = RecordSelection();
      await pump(tester, sel, _api());
      await tester.enterText(find.byKey(const ValueKey('record-search')), 'CLIENTE 12');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-all')));
      await tester.pumpAndSettle();
      // "CLIENTE 12", "CLIENTE 120".."CLIENTE 129"
      expect(sel.count, 11);
      expect(sel.rows.every((r) => '${r['name']}'.contains('CLIENTE 12')), isTrue);
    });

    testWidgets('a list without a selection has no checkboxes', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: RecordList(api: _api(), path: '/api/customers', columns: [col('Cliente', 'name')]))));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byKey(const ValueKey('select-all')), findsNothing);
    });

    testWidgets('on a phone the rows carry the checkbox too', (tester) async {
      final sel = RecordSelection();
      await pump(tester, sel, _api(total: 5), width: 400);
      await tester.tap(find.byKey(const ValueKey('select-3')));
      await tester.pump();
      expect(sel.rows.single['id'], 3);
    });
  });
}
