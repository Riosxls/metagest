import 'dart:convert';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/main.dart' show appTheme;
import 'package:ebt_engenharia/screens/duplicates.dart';
import 'package:ebt_engenharia/session.dart';
import 'package:ebt_engenharia/widgets/duplicates.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'role_permissions.dart';

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> rec(int id, String label, {String? detail}) => {'id': id, 'label': label, 'detail': detail, 'active': true};

Map<String, dynamic> pair(Map<String, dynamic> a, Map<String, dynamic> b, int score, List<String> reasons) => {
  'a': a,
  'b': b,
  'score': score,
  'reasons': [
    for (final r in reasons) {'code': 'x', 'text': r, 'score': score},
  ],
};

Session sessionFor(String role, MockClient client) =>
    Session(
        api: ApiClient(baseUrl: 'http://api.test', client: client, token: 'tok'),
      )
      ..username = 'ana'
      ..role = role
      ..permissions = rolePermissions[role]!;

Future<void> pumpApp(WidgetTester tester, Widget home) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(body: home),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final self = rec(1, 'Aço Alfa Ltda', detail: '11.222.333/0001-81');
  final other = rec(2, 'ACO ALFA S.A.', detail: 'Embu/SP');

  testWidgets('the banner lists the records that look alike with the reason, and a reviewer can mark the pair as not a duplicate', (tester) async {
    var matches = [
      pair(self, other, 100, ['Mesmo CNPJ/CPF', 'Mesmo nome']),
    ];
    var dismissed = <Map<String, dynamic>>[];
    final posts = <http.Request>[];
    final client = MockClient((r) async {
      if (r.url.path == '/api/customers/1/duplicates') return json({'matches': matches, 'dismissed': dismissed});
      if (r.method == 'POST' && r.url.path == '/api/duplicates/customers/1/2/dismiss') {
        posts.add(r);
        matches = [];
        dismissed = [
          {'id': 5, 'other': other, 'reason': 'Filiais', 'createdBy': 'ana', 'createdAt': '2026-11-11T10:00:00Z'},
        ];
        return http.Response('', 204);
      }
      if (r.method == 'DELETE' && r.url.path == '/api/duplicates/customers/1/2/dismiss') {
        dismissed = [];
        matches = [
          pair(self, other, 100, ['Mesmo CNPJ/CPF']),
        ];
        return http.Response('', 204);
      }
      return json({});
    });
    final opened = <int>[];
    await pumpApp(tester, DuplicatesBanner(session: sessionFor('Sales', client), kind: 'customers', id: 1, onOpen: opened.add));

    expect(find.text('Possíveis duplicados (1)'), findsOneWidget);
    expect(find.text('ACO ALFA S.A.'), findsWidgets);
    expect(find.textContaining('Mesmo CNPJ/CPF · Mesmo nome · 100%'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Abrir'));
    expect(opened, [2]);

    await tester.tap(find.text('Não é duplicado'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('prompt-text')), 'Filiais');
    await tester.tap(find.widgetWithText(FilledButton, 'Marcar'));
    await tester.pumpAndSettle();
    expect(jsonDecode(posts.single.body), {'reason': 'Filiais'});
    // The pair left the suspects and shows under the cleared ones, with a way back.
    expect(find.text('Possíveis duplicados (1)'), findsNothing);
    expect(find.text('Marcados como não duplicados (1)'), findsOneWidget);
    await tester.tap(find.text('Marcados como não duplicados (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Filiais · por ana'), findsOneWidget);
    await tester.tap(find.text('Voltar a sinalizar'));
    await tester.pumpAndSettle();
    expect(find.text('Possíveis duplicados (1)'), findsOneWidget);
  });

  testWidgets('a role without the review permission only reads the suspects', (tester) async {
    final client = MockClient(
      (r) async => json({
        'matches': [
          pair(self, other, 90, ['Mesmo nome']),
        ],
        'dismissed': <Object>[],
      }),
    );
    await pumpApp(tester, DuplicatesBanner(session: sessionFor('Reader', client), kind: 'products', id: 1, onOpen: (_) {}));
    expect(find.text('Possíveis duplicados (1)'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Abrir'), findsOneWidget);
    expect(find.text('Não é duplicado'), findsNothing);
  });

  testWidgets('the banner is invisible with nothing to say or when the list cannot be read', (tester) async {
    await pumpApp(
      tester,
      DuplicatesBanner(
        session: sessionFor('Sales', MockClient((r) async => json({'matches': <Object>[], 'dismissed': <Object>[]}))),
        kind: 'customers',
        id: 1,
        onOpen: (_) {},
      ),
    );
    expect(find.byKey(const ValueKey('duplicates-banner')), findsNothing);
    await pumpApp(
      tester,
      DuplicatesBanner(session: sessionFor('Sales', MockClient((r) async => json({'message': 'x'}, 500))), kind: 'suppliers', id: 1, onOpen: (_) {}),
    );
    expect(find.byKey(const ValueKey('duplicates-banner')), findsNothing);
  });

  testWidgets('the list screen shows the groups of each kind and marks a pair as not a duplicate', (tester) async {
    final asked = <String>[];
    var groups = [
      {
        'members': [self, other],
        'pairs': [
          pair(self, other, 100, ['Mesmo CNPJ/CPF']),
        ],
        'score': 100,
      },
    ];
    final client = MockClient((r) async {
      asked.add('${r.method} ${r.url.path}');
      if (r.method == 'GET' && r.url.path == '/api/duplicates/customers') return json({'groups': groups, 'pairs': groups.length, 'records': 2 * groups.length});
      if (r.method == 'GET' && r.url.path == '/api/duplicates/products') return json({'groups': <Object>[], 'pairs': 0, 'records': 0});
      if (r.method == 'POST' && r.url.path == '/api/duplicates/customers/1/2/dismiss') {
        groups = [];
        return http.Response('', 204);
      }
      return json({'groups': <Object>[], 'pairs': 0, 'records': 0});
    });
    await pumpApp(tester, DuplicatesScreen(session: sessionFor('SalesManager', client)));

    expect(find.text('1 grupo com 1 par suspeito'), findsOneWidget);
    expect(find.text('Aço Alfa Ltda'), findsWidgets);
    expect(find.textContaining('Mesmo CNPJ/CPF · 100%'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('dismiss-1-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Marcar'));
    await tester.pumpAndSettle();
    expect(asked, contains('POST /api/duplicates/customers/1/2/dismiss'));
    expect(find.text('Nenhum duplicado suspeito'), findsOneWidget);

    await tester.tap(find.text('Produtos'));
    await tester.pumpAndSettle();
    expect(asked, contains('GET /api/duplicates/products'));
    expect(find.text('Nenhum duplicado suspeito'), findsOneWidget);
  });

  testWidgets('"É o atual" opens the comparison with that record kept and sends the chosen values', (tester) async {
    var groups = [
      {
        'members': [self, other],
        'pairs': [
          pair(self, other, 100, ['Mesmo CNPJ/CPF']),
        ],
        'score': 100,
      },
    ];
    final posts = <Map<String, dynamic>>[];
    final client = MockClient((r) async {
      if (r.method == 'GET' && r.url.path == '/api/duplicates/customers') return json({'groups': groups, 'pairs': groups.length, 'records': 2 * groups.length});
      if (r.method == 'GET' && r.url.path == '/api/duplicates/customers/compare') {
        return json({
          'records': [
            {'id': 1, 'label': 'Aço Alfa Ltda', 'active': true, 'usage': [{'label': 'Pedidos de venda', 'count': 0}], 'addresses': 1},
            {'id': 2, 'label': 'ACO ALFA S.A.', 'active': true, 'usage': [{'label': 'Pedidos de venda', 'count': 5}], 'addresses': 2},
          ],
          'fields': [
            {'key': 'city', 'label': 'Cidade', 'values': {'1': 'Embu', '2': 'Embu das Artes'}, 'differs': true},
            {'key': 'phone', 'label': 'Telefone', 'values': {'1': null, '2': '1155550000'}, 'differs': true},
            {'key': 'uf', 'label': 'UF', 'values': {'1': 'SP', '2': 'SP'}, 'differs': false},
          ],
        });
      }
      if (r.method == 'POST' && r.url.path == '/api/duplicates/customers/resolve') {
        posts.add(jsonDecode(r.body) as Map<String, dynamic>);
        groups = [];
        return json({'keepId': 1, 'fieldsChanged': 2, 'addressesMoved': 2, 'deactivated': 1});
      }
      return json({'groups': <Object>[], 'pairs': 0, 'records': 0});
    });
    await pumpApp(tester, DuplicatesScreen(session: sessionFor('SalesManager', client), initialKind: 'customers'));

    await tester.tap(find.byKey(const ValueKey('current-1')));
    await tester.pumpAndSettle();
    expect(find.text('Comparar cadastros'), findsOneWidget);
    expect(find.text('Embu das Artes'), findsOneWidget);
    // UF is the same in both: hidden until asked for.
    expect(find.text('UF'), findsNothing);
    // Phone is empty on the kept record, so its default comes from the other one.
    await tester.tap(find.byKey(const ValueKey('pick-city-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compare-confirm')));
    await tester.pumpAndSettle();

    expect(posts.single['keepId'], 1);
    expect(posts.single['otherIds'], [2]);
    expect(posts.single['fields'], {'city': 2, 'phone': 2});
    expect(posts.single['moveAddresses'], true);
    expect(find.text('Nenhum duplicado suspeito'), findsOneWidget);
  });

  testWidgets('the pencil types a value when no record has the right one and sends it as custom', (tester) async {
    final posts = <Map<String, dynamic>>[];
    final client = MockClient((r) async {
      if (r.method == 'GET' && r.url.path == '/api/duplicates/customers') {
        return json({
          'groups': [
            {
              'members': [self, other],
              'pairs': [
                pair(self, other, 100, ['Mesmo CNPJ/CPF']),
              ],
              'score': 100,
            },
          ],
          'pairs': 1,
          'records': 2,
        });
      }
      if (r.method == 'GET' && r.url.path == '/api/duplicates/customers/compare') {
        return json({
          'records': [
            {'id': 1, 'label': 'A', 'active': true, 'usage': [], 'addresses': 1},
            {'id': 2, 'label': 'B', 'active': true, 'usage': [], 'addresses': 1},
          ],
          'fields': [
            {'key': 'name', 'label': 'Nome', 'values': {'1': 'ACO ALFA', '2': 'AÇO ALFA LTDA'}, 'differs': true},
          ],
        });
      }
      if (r.method == 'POST' && r.url.path == '/api/duplicates/customers/resolve') {
        posts.add(jsonDecode(r.body) as Map<String, dynamic>);
        return json({'keepId': 1, 'fieldsChanged': 1, 'addressesMoved': 0, 'deactivated': 1});
      }
      return json({'groups': <Object>[], 'pairs': 0, 'records': 0});
    });
    await pumpApp(tester, DuplicatesScreen(session: sessionFor('SalesManager', client), initialKind: 'customers'));
    await tester.tap(find.byKey(const ValueKey('current-1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('edit-name')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Aço Alfa Indústria Ltda');
    await tester.tap(find.widgetWithText(FilledButton, 'Usar este valor'));
    await tester.pumpAndSettle();
    expect(find.text('Valor digitado'), findsOneWidget);
    expect(find.text('Aço Alfa Indústria Ltda'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('compare-confirm')));
    await tester.pumpAndSettle();
    expect(posts.single['custom'], {'name': 'Aço Alfa Indústria Ltda'});
    expect(posts.single['fields'], isEmpty);
  });

  testWidgets('the list screen reports a load failure with a retry', (tester) async {
    await pumpApp(tester, DuplicatesScreen(session: sessionFor('Sales', MockClient((r) async => json({'message': 'Banco indisponível'}, 500)))));
    expect(find.text('Tentar novamente'), findsOneWidget);
  });

  group('the Atenção strip on the lists', () {
    Map<String, dynamic> groupsOf(int n) => {
      'groups': [
        for (var i = 0; i < n; i++)
          {
            'members': [rec(i * 2 + 1, 'Cliente ${i * 2 + 1}'), rec(i * 2 + 2, 'Cliente ${i * 2 + 2}')],
            'pairs': [],
          },
      ],
      'pairs': n,
      'records': n * 2,
    };

    testWidgets('shows only when there are suspects, says how many, and a tap opens the duplicates screen on that kind', (tester) async {
      final paths = <String>[];
      final client = MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path == '/api/duplicates/suppliers') return json(groupsOf(2));
        if (r.url.path.startsWith('/api/duplicates/')) return json({'groups': [], 'pairs': 0, 'records': 0});
        return json({'items': [], 'total': 0, 'skip': 0, 'take': 50});
      });
      final session = sessionFor('Sales', client);
      await pumpApp(
        tester,
        Column(
          children: [DuplicatesAlert(key: const ValueKey('c'), session: session, kind: 'customers')],
        ),
      );
      expect(find.byKey(const ValueKey('duplicates-alert')), findsNothing, reason: 'nothing suspected: nothing shown');

      await pumpApp(
        tester,
        Column(
          children: [DuplicatesAlert(key: const ValueKey('s'), session: session, kind: 'suppliers')],
        ),
      );
      expect(find.text('2 grupos de fornecedores parecem duplicados'), findsOneWidget);
      expect(find.text('Ver'), findsNothing, reason: 'the strip has only the X');
      // The way in is the attention button of the toolbar.
      await pumpApp(
        tester,
        Column(
          children: [DuplicatesButton(session: session, kind: 'suppliers')],
        ),
      );
      await tester.tap(find.byKey(const ValueKey('attention-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 grupos de fornecedores parecem duplicados'));
      await tester.pumpAndSettle();
      expect(find.text('Cadastros duplicados'), findsOneWidget);
      // The screen opens on the Fornecedores tab.
      expect(paths.where((p) => p == '/api/duplicates/suppliers').length, greaterThanOrEqualTo(2));
    });

    testWidgets('one group is said in the singular, and a failed check shows nothing', (tester) async {
      final one = sessionFor('Sales', MockClient((r) async => json(groupsOf(1))));
      await pumpApp(
        tester,
        Column(
          children: [DuplicatesAlert(key: const ValueKey('one'), session: one, kind: 'products')],
        ),
      );
      expect(find.text('1 grupo de produtos parece duplicado'), findsOneWidget);

      // The X hides the strip for good (the button of the toolbar stays).
      await tester.tap(find.byKey(const ValueKey('dismiss-notice-products-duplicates')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('duplicates-alert')), findsNothing);

      final broken = sessionFor('Sales', MockClient((r) async => json({'message': 'x'}, 500)));
      await pumpApp(
        tester,
        Column(
          children: [DuplicatesAlert(key: const ValueKey('broken'), session: broken, kind: 'products')],
        ),
      );
      expect(find.byKey(const ValueKey('duplicates-alert')), findsNothing);
    });
  });
}
