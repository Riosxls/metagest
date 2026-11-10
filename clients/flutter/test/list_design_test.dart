import 'dart:convert';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/entities.dart';
import 'package:ebt_engenharia/widgets/record_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a value that rounds to zero is 0, not "0,"', () {
    expect(fmt(0.00001), '0');
    expect(fmt(0.2907), '0,2907');
    expect(fmt(1), '1');
  });

  test('product and material columns: badge cells, dashes for zeros, two decimals for the wall', () {
    String cell(EntitySpec s, String label, Map<String, dynamic> e) => s.columns.firstWhere((c) => c.label == label).value(e);
    expect(cell(products, 'Operações', {'operationCount': 0}), '');
    expect(cell(products, 'Operações', {'operationCount': 3}), '3');
    expect(cell(products, 'Situação', {'blocked': true}), 'Bloqueado');
    expect(cell(materials, 'Espessura', {'thicknessMm': 0.6}), '0,60');
    expect(cell(materials, 'Espessura', {'thicknessMm': 1}), '1,00');
    expect(cell(materials, 'Espessura', {'thicknessMm': null}), '');
    expect(cell(materials, 'Situação', {'active': false}), 'Inativo');
  });

  testWidgets('a table narrower than the window stretches to fill it, and the search is the rounded one', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient((r) async => http.Response(jsonEncode({'items': [{'a': 'x', 'b': 'y'}], 'total': 1, 'skip': 0, 'take': 50}), 200, headers: {'content-type': 'application/json; charset=utf-8'}));
    final api = ApiClient(baseUrl: 'http://api.test', client: client, token: 't');
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('pt', 'BR'),
        supportedLocales: const [Locale('pt', 'BR')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(body: RecordList(api: api, path: '/x', columns: [col('A', 'a'), col('B', 'b')])),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(DataTable)).width, greaterThan(1700));
    final field = tester.widget<TextField>(find.byKey(const ValueKey('record-search')));
    expect(field.decoration!.filled, isTrue);
  });
}
