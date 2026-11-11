import 'dart:convert';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/entities.dart';
import 'package:ebt_engenharia/reports/entity_docs.dart';
import 'package:ebt_engenharia/screens/entity_selection.dart';
import 'package:ebt_engenharia/widgets/record_selection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _product(int i, {bool blocked = false}) => {
  'id': i,
  'code': '060.0$i',
  'name': 'TUBO-C 6,00 X 0,8$i X 3000MM',
  'kind': 'Part',
  'shape': 'Round',
  'diameterMm': 6,
  'thicknessMm': 0.8,
  'lengthMm': 3000,
  'netWeightKg': 0.3078,
  'ncm': '73063000',
  'stockUnit': 'PC',
  'blocked': blocked,
  'operationCount': 7,
};

({double w, double h}) _page(List<int> bytes) {
  final m = RegExp(r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]').firstMatch(latin1.decode(bytes, allowInvalid: true))!;
  return (w: double.parse(m.group(1)!), h: double.parse(m.group(2)!));
}

void main() {
  group('entity PDFs', () {
    test('one product: a portrait sheet with every field of the form', () async {
      final bytes = await buildEntityPdf(products, [_product(1)]);
      final p = _page(bytes);
      expect(p.h, greaterThan(p.w));
      expect(RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes, allowInvalid: true)).length, 1);
    });

    test('several products: a landscape list over several pages', () async {
      final bytes = await buildEntityPdf(products, [for (var i = 1; i <= 120; i++) _product(i)], filters: ['Busca: tubo']);
      final p = _page(bytes);
      expect(p.w, greaterThan(p.h));
      expect(RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(bytes, allowInvalid: true)).length, greaterThan(1));
    });

    test('field values: choices by label, booleans as Sim/Não, lookups only when the row names them', () {
      const choice = FieldSpec('kind', 'Tipo', type: FieldType.choice, choices: {'Part': 'Peça'});
      expect(entityFieldValue(choice, {'kind': 'Part'}), 'Peça');
      const lookup = FieldSpec('classId', 'Classe', type: FieldType.lookup);
      expect(entityFieldValue(lookup, {'classId': 3}), '');
      expect(entityFieldValue(lookup, {'classId': 3, 'className': 'Tubos'}), 'Tubos');
      expect(entityFieldValue(const FieldSpec('blocked', 'Bloqueado', type: FieldType.boolean), {'blocked': true}), 'Sim');
      expect(entityFieldValue(choice, {'kind': null}), '');
    });
  });

  group('entity selection actions', () {
    Future<List<Map<String, dynamic>>> run(WidgetTester tester, Future<int> Function(BuildContext, ApiClient) act, String confirmLabel, {Set<int> refuse = const {}}) async {
      final calls = <Map<String, dynamic>>[];
      final client = MockClient((r) async {
        final id = int.tryParse(r.url.pathSegments.last) ?? -1;
        calls.add({'method': r.method, 'path': r.url.path, if (r.body.isNotEmpty) ...jsonDecode(r.body) as Map<String, dynamic>});
        return refuse.contains(id) ? _json({'title': 'in use'}, 409) : (r.method == 'DELETE' ? http.Response('', 204) : _json({}));
      });
      final api = ApiClient(baseUrl: 'http://api.test', client: client, token: 't');
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const Scaffold();
            },
          ),
        ),
      );
      final f = act(ctx, api);
      await tester.pumpAndSettle();
      await tester.tap(find.text(confirmLabel));
      await tester.pumpAndSettle();
      if (find.text('Fechar').evaluate().isNotEmpty) await tester.tap(find.text('Fechar'));
      await tester.pumpAndSettle();
      await f;
      return calls;
    }

    testWidgets('excluir deletes each selected product and clears the selection', (tester) async {
      final sel = RecordSelection()..addAll([_product(1), _product(2)]);
      final calls = await run(tester, (c, a) => deleteRecords(c, a, products, sel), 'Excluir');
      expect(calls.map((c) => '${c['method']} ${c['path']}'), ['DELETE /api/products/1', 'DELETE /api/products/2']);
      expect(sel.isEmpty, isTrue);
    });

    testWidgets('a product in use is refused and stays selected', (tester) async {
      final sel = RecordSelection()..addAll([_product(1), _product(2)]);
      await run(tester, (c, a) => deleteRecords(c, a, products, sel), 'Excluir', refuse: {2});
      expect(sel.rows.map((r) => r['id']), [2]);
    });

    testWidgets('inativar sends the whole row with blocked true, only for unblocked ones', (tester) async {
      final sel = RecordSelection()..addAll([_product(1), _product(2, blocked: true)]);
      final calls = await run(tester, (c, a) => setFlag(c, a, products, sel, flag: 'blocked', off: true), 'Inativar');
      expect(calls.length, 1);
      expect(calls.single['method'], 'PUT');
      expect(calls.single['blocked'], true);
      expect(calls.single['code'], '060.01');
    });

    test('the status flag follows the row: blocked for products, active for the rest, none otherwise', () {
      expect(statusFlag([_product(1)]), 'blocked');
      expect(statusFlag([{'id': 1, 'active': true}]), 'active');
      expect(statusFlag([{'id': 1}]), isNull);
      expect(selectionIsOff('blocked', [_product(1, blocked: true)]), isTrue);
      expect(selectionIsOff('active', [{'active': false}, {'active': true}]), isFalse);
      expect(entityPrintFormat(1).width, lessThan(entityPrintFormat(2).width));
    });
  });
}
