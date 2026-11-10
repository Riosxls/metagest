import 'dart:convert';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/screens/customers.dart';
import 'package:ebt_engenharia/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'role_permissions.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});

Map<String, dynamic> _page(List<Map<String, dynamic>> items) => {'items': items, 'total': items.length, 'skip': 0, 'take': 50};

Map<String, dynamic> _customer({bool active = true, bool withCompany = true, num? creditLimit}) => {
  'id': 1, 'name': 'Metalúrgica Alfa', 'tradeName': 'Alfa', 'legacyCode': '12', 'consumerType': 'Normal', 'active': active,
  'company': withCompany
      ? {'document': '12345678000199', 'stateRegistration': '111', 'icmsContributor': true, 'street': 'Rua A', 'number': '10', 'city': 'Sorocaba', 'uf': 'SP', 'contact': 'Ana', 'email': 'a@alfa.com', 'phone': '1500', 'paymentTermName': '28 dias', 'creditLimit': creditLimit}
      : null,
  'defaultAddress': null,
};

Map<String, dynamic> _address(int id) => {'id': id, 'city': 'Sorocaba', 'uf': 'SP', 'street': 'Rua B', 'number': '5', 'buyer': 'Beto', 'email': 'b@alfa.com', 'phone': '1511'};

class _Env {
  _Env({this.addresses = const [], this.withCompany = true, this.creditLimit, this.openOrders = 0});

  final List<Map<String, dynamic>> addresses;
  final bool withCompany;
  final num? creditLimit;

  /// Unshipped value (with IPI) of the customer's open orders.
  final num openOrders;
  final log = <http.Request>[];

  http.Response answer(http.Request r) {
    log.add(r);
    final path = r.url.path;
    if (r.method == 'POST') return _json({..._customer(), 'id': 9});
    if (r.method == 'PUT' && path == '/api/customers/1') {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      return _json({..._customer(withCompany: withCompany), ...body});
    }
    if (r.method == 'PUT') return _json({..._address(5), ...(jsonDecode(r.body) as Map<String, dynamic>)});
    if (r.method == 'DELETE') return http.Response('', 204);
    if (path == '/api/receivables/balances') {
      return _json([
        {'customerId': 1, 'customerName': 'Metalúrgica Alfa', 'open': 1500, 'overdue': 400, 'nextDue': '2026-11-20'},
      ]);
    }
    if (path == '/api/sales/orders') {
      return _json(
        _page([
          if (openOrders > 0) {'id': 5, 'reference': 'PV 5', 'balanceValue': openOrders - 100, 'balanceWithIpi': openOrders},
        ]),
      );
    }
    if (path == '/api/customers/1/addresses') return _json(addresses);
    if (path == '/api/customers/1') return _json(_customer(withCompany: withCompany));
    if (path == '/api/customers') return _json(_page([_customer(withCompany: withCompany)]));
    return _json(_page([]));
  }
}

Future<void> _pump(WidgetTester tester, _Env env, Widget Function(Session) screen, {String role = 'Admin'}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = const Size(1800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = Session(api: ApiClient(baseUrl: 'http://api.test', client: MockClient((r) async => env.answer(r)), token: 'tok'))
    ..username = 'u'
    ..role = role
    ..permissions = rolePermissions[role]!;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('pt', 'BR'),
      supportedLocales: const [Locale('pt', 'BR')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(body: screen(session)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('fmtDocument formats CPF and CNPJ and leaves other values alone', () {
    expect(fmtDocument('12345678901'), '123.456.789-01');
    expect(fmtDocument('12345678000199'), '12.345.678/0001-99');
    expect(fmtDocument('abc'), 'abc');
    expect(fmtDocument(null), '');
  });

  testWidgets('customer list shows company columns and asks for active customers', (tester) async {
    final env = _Env();
    await _pump(tester, env, (s) => CustomersScreen(session: s));
    expect(find.text('Metalúrgica Alfa'), findsOneWidget);
    expect(find.text('12.345.678/0001-99'), findsOneWidget);
    expect(find.text('Sorocaba/SP'), findsOneWidget);
    expect(env.log.first.url.queryParameters['active'], 'true');
  });

  testWidgets('new customer posts company data and a first delivery address', (tester) async {
    final env = _Env();
    await _pump(tester, env, (s) => CustomersScreen(session: s));
    await tester.tap(find.text('Novo cliente'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-name')), 'Nova Ltda');
    await tester.enterText(find.byKey(const ValueKey('field-company.document')), '98765432000111');
    await tester.ensureVisible(find.byKey(const ValueKey('field-company.uf')));
    await tester.tap(find.byKey(const ValueKey('field-company.uf')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AC').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-company.contact')), 'Carla');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    final post = env.log.firstWhere((r) => r.method == 'POST');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(post.url.path, '/api/customers');
    expect(body['name'], 'Nova Ltda');
    expect(body['company']['document'], '98765432000111');
    expect(body['address']['uf'], 'AC');
    expect(body['address']['buyer'], 'Carla');
  });

  testWidgets('customer screen shows company data, edits it and inactivates the customer', (tester) async {
    final env = _Env(addresses: [_address(5), _address(6)]);
    await _pump(tester, env, (s) => CustomerScreen(session: s, customer: _customer()));
    expect(find.text('Dados da empresa'), findsOneWidget);
    expect(find.text('12.345.678/0001-99'), findsOneWidget);
    await tester.tap(find.byTooltip('Editar cadastro'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-name')), 'Alfa Nova');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    final put = env.log.firstWhere((r) => r.method == 'PUT');
    expect(jsonDecode(put.body)['name'], 'Alfa Nova');
    expect(find.textContaining('Alfa Nova'), findsWidgets);

    await tester.tap(find.byTooltip('Inativar'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Inativar este cliente?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Inativar'));
    await tester.pumpAndSettle();
    expect(jsonDecode(env.log.where((r) => r.method == 'PUT').last.body)['active'], false);
    expect(find.textContaining('(inativo)'), findsOneWidget);
    expect(find.byTooltip('Reativar'), findsOneWidget);
  });

  testWidgets('customer screen shows the open and overdue receivable balance', (tester) async {
    await _pump(tester, _Env(), (s) => CustomerScreen(session: s, customer: _customer()));
    expect(find.text('Contas a receber'), findsOneWidget);
    // The same R$ 1.500,00 also feeds the credit exposure above it.
    expect(find.text('R\$ 1.500,00'), findsWidgets);
    expect(find.text('R\$ 400,00'), findsOneWidget);
  });

  testWidgets('customer screen shows the credit limit, the exposure and warns when it is over', (tester) async {
    final env = _Env(creditLimit: 2000, openOrders: 800);
    await _pump(tester, env, (s) => CustomerScreen(session: s, customer: _customer(creditLimit: 2000)));
    expect(find.byKey(const ValueKey('customer-credit')), findsOneWidget);
    expect(find.text('R\$ 2.000,00'), findsOneWidget); // limit
    expect(find.text('R\$ 800,00'), findsOneWidget); // open orders (balanceWithIpi)
    expect(find.text('R\$ 2.300,00'), findsOneWidget); // exposure: 800 + 1.500
    expect(find.text('R\$ -300,00'), findsOneWidget); // what is left
    expect(find.textContaining('Acima do limite'), findsOneWidget);
    expect(env.log.any((r) => r.url.path == '/api/sales/orders' && r.url.queryParameters['customerId'] == '1' && r.url.queryParameters['open'] == 'true'), isTrue);
  });

  testWidgets('within the limit there is no warning', (tester) async {
    await _pump(tester, _Env(creditLimit: 5000, openOrders: 800), (s) => CustomerScreen(session: s, customer: _customer(creditLimit: 5000)));
    expect(find.text('R\$ 5.000,00'), findsOneWidget);
    expect(find.textContaining('Acima do limite'), findsNothing);
  });

  testWidgets('without a limit of its own the prazo decides', (tester) async {
    await _pump(tester, _Env(), (s) => CustomerScreen(session: s, customer: _customer()));
    expect(find.textContaining('limite do prazo 28 dias'), findsOneWidget);
  });

  testWidgets('customer without company data points to Editar', (tester) async {
    await _pump(tester, _Env(withCompany: false), (s) => CustomerScreen(session: s, customer: _customer(withCompany: false)));
    expect(find.textContaining('Sem dados cadastrados'), findsOneWidget);
  });

  testWidgets('delivery locais list marks the default and edits one', (tester) async {
    final env = _Env(addresses: [_address(5), _address(6)]);
    await _pump(tester, env, (s) => CustomerScreen(session: s, customer: _customer()));
    await tester.tap(find.text('Locais de entrega'));
    await tester.pumpAndSettle();
    expect(find.text('Sorocaba/SP  (padrão)'), findsOneWidget);
    expect(find.byTooltip('Local padrão'), findsOneWidget);
    await tester.tap(find.text('Sorocaba/SP  (padrão)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-buyer')), 'Dani');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    final put = env.log.firstWhere((r) => r.method == 'PUT' && r.url.path == '/api/customers/1/addresses/5');
    expect(jsonDecode(put.body)['buyer'], 'Dani');
  });

  testWidgets('new delivery local copies the company fiscal data', (tester) async {
    final env = _Env();
    await _pump(tester, env, (s) => CustomerScreen(session: s, customer: _customer()));
    await tester.tap(find.text('Locais de entrega'));
    await tester.pumpAndSettle();
    expect(find.text('Nenhum local de entrega'), findsOneWidget);
    await tester.tap(find.text('Novo local'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('field-uf')));
    await tester.tap(find.byKey(const ValueKey('field-uf')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('AC').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-city')), 'Votorantim');
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    final post = env.log.firstWhere((r) => r.method == 'POST' && r.url.path == '/api/customers/1/addresses');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['document'], '12345678000199');
    expect(body['city'], 'Votorantim');
  });

  testWidgets('new delivery local asks for company data first when there is none', (tester) async {
    final env = _Env(withCompany: false);
    await _pump(tester, env, (s) => CustomerScreen(session: s, customer: _customer(withCompany: false)));
    await tester.tap(find.text('Locais de entrega'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Novo local'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cadastre os dados da empresa'), findsOneWidget);
  });

  testWidgets('quotes and orders tabs load the customer records', (tester) async {
    final env = _Env();
    await _pump(tester, env, (s) => CustomerScreen(session: s, customer: _customer()));
    await tester.tap(find.text('Orçamentos'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pedidos'));
    await tester.pumpAndSettle();
    expect(env.log.any((r) => r.url.path == '/api/sales/quotes' && r.url.queryParameters['customerId'] == '1'), isTrue);
    expect(env.log.any((r) => r.url.path == '/api/sales/orders' && r.url.queryParameters['customerId'] == '1'), isTrue);
  });

  testWidgets('read-only role cannot create customers', (tester) async {
    await _pump(tester, _Env(), (s) => CustomersScreen(session: s), role: 'Reader');
    expect(find.text('Novo cliente'), findsNothing);
  });

  testWidgets('read-only role cannot inactivate or edit company data', (tester) async {
    await _pump(tester, _Env(addresses: [_address(5)]), (s) => CustomerScreen(session: s, customer: _customer()), role: 'Reader');
    expect(find.byTooltip('Inativar'), findsNothing);
    expect(find.text('Editar'), findsNothing);
  });

  testWidgets('the customer page opens with a summary header and the contact card copies a value', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await _pump(tester, _Env(), (s) => CustomerScreen(session: s, customer: _customer()));
    expect(find.byKey(const ValueKey('customer-avatar')), findsOneWidget);
    expect(find.text('MA'), findsOneWidget);
    expect(find.text('Ativo'), findsOneWidget);
    expect(find.text('Sorocaba/SP'), findsWidgets);
    expect(find.text('Endereço principal'), findsOneWidget);
    expect(find.text('Contato'), findsWidgets);
    await tester.tap(find.byTooltip('Copiar E-mail'));
    await tester.pump();
    expect(copied, 'a@alfa.com');
    expect(find.text('E-mail copiado'), findsOneWidget);
  });

  testWidgets('the list is a contact list: letter headings, avatars with initials and the columns of a customer', (tester) async {
    await _pump(tester, _Env(), (s) => CustomersScreen(session: s));
    expect(find.text('M'), findsOneWidget); // heading of "Metalúrgica Alfa"
    expect(find.text('MA'), findsOneWidget); // its avatar
    expect(find.text('NOME'), findsOneWidget);
    expect(find.text('a@alfa.com'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget); // who to ask for, under the e-mail
    expect(find.text('(15) 00'), findsNothing); // the 4-digit test phone stays as typed, not mangled
  });

  testWidgets('on a narrow screen a customer is the name with its data on one line', (tester) async {
    await _pump(tester, _Env(), (s) => CustomersScreen(session: s));
    tester.view.physicalSize = const Size(600, 900);
    await tester.pumpAndSettle();
    expect(find.text('Metalúrgica Alfa'), findsOneWidget);
    expect(find.textContaining('a@alfa.com'), findsOneWidget);
    expect(find.text('NOME'), findsNothing);
  });

  test('initials skip the words every company has, and a phone field with several numbers shows the first', () {
    expect(contactInitials('ACOS IDEAL LTDA.'), 'AI');
    expect(contactInitials('AMVIAN IND E COM DE PECAS AUTOMOTIVAS LTDA'), 'AP');
    expect(contactInitials('Metalúrgica Gepela Ltda.'), 'MG');
    expect(contactInitials('Alberto Ferreira Pacheco Filho'), 'AF');
    expect(contactInitials('Ltda'), 'L');
    expect(contactPhones('1129584633/26820000').more, 1);
    expect(contactPhones('1129584633').more, 0);
    expect(contactPhones('1129584633').first, '(11) 2958-4633');
    expect(contactPhones('').first, '');
  });
}
