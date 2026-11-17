import 'dart:convert';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/widgets/attention.dart';
import 'package:ebt_engenharia/widgets/fiscal_problems.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _p(int id, String name, int orders, List<String> gaps) => {
  'customerId': id,
  'name': name,
  'openOrders': orders,
  'addresses': [
    {'addressId': id * 10, 'label': 'Rua Inco · Diadema', 'gaps': gaps},
  ],
};

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('the strip says how many customers cannot be invoiced and how many have open orders; the attention button lists them with what each lacks', (tester) async {
    final opened = <int>[];
    final problems = [
      _p(1, 'Sem pedido', 0, ['CEP']),
      _p(2, 'Com pedido', 2, ['código IBGE do município', 'endereço']),
    ];
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            FiscalProblemsAlert(problems: problems),
            Builder(builder: (context) => AttentionButton(notices: [fiscalProblemsNotice(context, problems, opened.add)])),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('2 clientes com cadastro incompleto para emitir NF · 1 com pedido em aberto'), findsOneWidget);
    expect(find.text('Ver'), findsNothing, reason: 'the strip has only the X');
    await tester.tap(find.byKey(const ValueKey('attention-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('2 clientes com cadastro incompleto').last);
    await tester.pumpAndSettle();
    expect(find.text('Cadastros incompletos para a NF (2)'), findsOneWidget);
    expect(find.textContaining('código IBGE do município, endereço'), findsOneWidget);
    // those with open orders come first
    expect(tester.getTopLeft(find.byKey(const ValueKey('fiscal-problem-row-2'))).dy, lessThan(tester.getTopLeft(find.byKey(const ValueKey('fiscal-problem-row-1'))).dy));
    await tester.tap(find.byKey(const ValueKey('fiscal-problem-row-2')));
    await tester.pumpAndSettle();
    expect(opened, [2]);
  });

  testWidgets('nothing is shown when every register is complete', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const FiscalProblemsAlert(problems: [])));
    expect(find.byKey(const ValueKey('fiscal-problems-alert')), findsNothing);
    await tester.pumpWidget(_app(const FiscalProblemBanner(problem: null)));
    expect(find.byKey(const ValueKey('fiscal-problem-banner')), findsNothing);
  });

  testWidgets('the badge and the customer banner name what is missing', (tester) async {
    final p = _p(7, 'Incodiesel', 1, ['código IBGE do município']);
    await tester.pumpWidget(_app(Column(children: [FiscalProblemBadge(problem: p), FiscalProblemBanner(problem: p)])));
    expect(find.byKey(const ValueKey('fiscal-problem-7')), findsOneWidget);
    expect(find.text('Cadastro incompleto para emitir NF'), findsOneWidget);
    expect(find.text('Rua Inco · Diadema: código IBGE do município'), findsOneWidget);
  });

  test('a failed read is a hint that is simply absent', () async {
    final ok = ApiClient(baseUrl: 'http://api.test', client: MockClient((r) async => http.Response(jsonEncode([_p(1, 'X', 0, ['CEP'])]), 200, headers: {'content-type': 'application/json'})), token: 't');
    expect((await fetchFiscalProblems(ok)).length, 1);
    final broken = ApiClient(baseUrl: 'http://api.test', client: MockClient((r) async => http.Response('{"message":"x"}', 500)), token: 't');
    expect(await fetchFiscalProblems(broken), isEmpty);
  });
}
