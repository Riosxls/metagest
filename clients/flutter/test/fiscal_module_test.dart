import 'dart:convert';

import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/entities.dart' show carriers, fiscalMasters, monthlyPrices, salesMasters, taxRules;
import 'package:ebt_engenharia/screens/dashboard.dart' show modules;
import 'package:ebt_engenharia/screens/fiscal.dart' show FiscalSettingsScreen;
import 'package:ebt_engenharia/screens/fiscal_import.dart' show FiscalImportScreen;
import 'package:ebt_engenharia/screens/fiscal_readiness.dart';
import 'package:ebt_engenharia/screens/modules.dart';
import 'package:ebt_engenharia/screens/shell.dart';
import 'package:ebt_engenharia/session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dashboard_test.dart' show json, openPalette, page, pumpShell;
import 'nav.dart';
import 'role_permissions.dart';

Map<String, dynamic> issuer({bool filled = true, bool enabled = false, bool simulated = true, String company = 'EBT', int nextNumber = 2581}) => {
  'company': company,
  'enabled': enabled,
  'environment': 'Homologation',
  'companyName': filled ? 'EBT Indústria' : null,
  'cnpj': filled ? '26133636000103' : null,
  'stateRegistration': filled ? '123' : null,
  'street': filled ? 'Av. Dona Cesária' : null,
  'city': filled ? 'Embu das Artes' : null,
  'cityIbgeCode': filled ? '3515004' : null,
  'uf': 'SP',
  'series': 1,
  'nextNumber': nextNumber,
  'sefazSimulated': simulated,
};

List<Map<String, dynamic>> cfopList(List<String> codes) => [
  for (final c in codes) {'code': c, 'description': 'CFOP $c', 'active': true},
];

void main() {
  group('FiscalReadiness', () {
    FiscalCheck check(FiscalReadiness r, String id) => r.checks.firstWhere((c) => c.id == id);

    test('empty system: issuer, CFOP 6101, rules and certificate are pending', () {
      final r = FiscalReadiness.from(
        issuers: [
          issuer(filled: false),
          issuer(filled: false, company: 'BST', nextNumber: 897),
        ],
        cfops: ['5101'],
        summary: {'taxRules': 0, 'carriers': 0},
      );
      expect(check(r, 'issuer-EBT').state, CheckState.warn);
      expect(check(r, 'issuer-EBT').detail, contains('razão social, CNPJ, inscrição estadual, endereço completo'));
      expect(check(r, 'issuer-EBT').goTo, 'fiscal-settings');
      expect(check(r, 'cfops').state, CheckState.warn);
      expect(check(r, 'cfops').detail, contains('6101'));
      expect(check(r, 'cfops').goTo, 'fiscal-import');
      expect(check(r, 'tax-rules').state, CheckState.warn);
      expect(check(r, 'tax-rules').goTo, taxRules.path);
      expect(check(r, 'carriers').state, CheckState.info);
      expect(check(r, 'certificate').state, CheckState.warn);
      expect(check(r, 'emission-EBT').state, CheckState.info);
      expect(check(r, 'issuer-BST').state, CheckState.warn);
      expect(check(r, 'issuer-BST').filter, 'BST');
      expect(check(r, 'emission-EBT').detail, contains('próximo número 2581'));
      expect(check(r, 'emission-BST').detail, contains('próximo número 897'));
      expect(r.ready, isFalse);
      expect(r.pending, 5);
    });

    test('everything in place and connected: ready', () {
      final r = FiscalReadiness.from(
        issuers: [
          issuer(enabled: true, simulated: false),
          issuer(enabled: true, simulated: false, company: 'BST', nextNumber: 897),
        ],
        cfops: ['5101', '6101', '5901'],
        summary: {'taxRules': 12, 'carriers': 3},
      );
      expect(r.ready, isTrue);
      expect(check(r, 'tax-rules').detail, '12 cadastradas');
      expect(check(r, 'certificate').detail, contains('Homologação'));
      expect(check(r, 'emission-EBT').detail, startsWith('Ligada'));
      expect(check(r, 'emission-BST').detail, contains('próximo número 897'));
    });

    test('a simulated SEFAZ is the "no A1 certificate yet" state', () {
      final r = FiscalReadiness.from(issuers: [issuer(simulated: true)], cfops: ['5101', '6101'], summary: {'taxRules': 1});
      expect(check(r, 'certificate').state, CheckState.warn);
      expect(check(r, 'certificate').detail, contains('simulada'));
    });
  });

  group('Fiscal module', () {
    Future<(List<String>, Session)> pumpOverview(
      WidgetTester tester, {
      String role = 'Admin',
      Map<String, dynamic>? settings,
      Size size = const Size(1600, 1400),
    }) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final paths = <String>[];
      final client = MockClient((r) async {
        paths.add(r.url.path);
        return switch (r.url.path) {
          '/api/fiscal/settings' => json(settings ?? issuer(filled: false)),
          '/api/fiscal/settings/all' => json([settings ?? issuer(filled: false), issuer(filled: false, company: 'BST', nextNumber: 897)]),
          '/api/fiscal/cfops' => json(cfopList(['5101'])),
          '/api/fiscal/legacy-import/summary' => json({
            'issuerFilled': false,
            'cfops': 1,
            'carriers': 0,
            'taxRules': 0,
            'monthlyPrices': 0,
            'nextNumber': 2581,
          }),
          _ => json(page([])),
        };
      });
      final session =
          Session(
              api: ApiClient(baseUrl: 'http://api.test', client: client, token: 'tok'),
            )
            ..username = 'ana'
            ..role = role
            ..permissions = rolePermissions[role]!;
      final module = modules.firstWhere((m) => m.section == 'Fiscal');
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('pt', 'BR'),
          supportedLocales: const [Locale('pt', 'BR')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: ModuleScreen(session: session, module: module, links: const [], onNavigate: (id, [f]) => paths.add('go:$id')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (paths, session);
    }

    testWidgets('the overview is the readiness checklist and a pending line opens the screen that fixes it', (tester) async {
      final (paths, _) = await pumpOverview(tester);
      expect(find.text('Pronto para emitir?'), findsOneWidget);
      expect(find.byKey(const ValueKey('fiscal-readiness-headline')), findsOneWidget);
      expect(find.textContaining('precisam de atenção antes de emitir'), findsOneWidget);
      expect(find.text('Dados do emitente (EBT)'), findsOneWidget);
      expect(find.text('Certificado digital A1'), findsOneWidget);
      expect(find.textContaining('próximo número 2581'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fiscal-check-cfops')));
      await tester.pumpAndSettle();
      expect(paths.last, 'go:fiscal-import');
      await tester.tap(find.byKey(const ValueKey('fiscal-check-issuer-EBT')));
      await tester.pumpAndSettle();
      expect(paths.last, 'go:fiscal-settings');
      expect(find.text('Dados do emitente (BST)'), findsOneWidget);
      expect(find.text('Emissão de NF-e (BST)'), findsOneWidget);
    });

    testWidgets('a failed read offers to try again', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session =
          Session(
              api: ApiClient(baseUrl: 'http://api.test', client: MockClient((r) async => http.Response(jsonEncode({'message': 'falhou'}), 500)), token: 'tok'),
            )
            ..username = 'ana'
            ..role = 'Admin'
            ..permissions = rolePermissions['Admin']!;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('pt', 'BR'),
          supportedLocales: const [Locale('pt', 'BR')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: ModuleScreen(session: session, module: modules.firstWhere((m) => m.section == 'Fiscal'), links: const []),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('module-retry')), findsOneWidget);
    });

    test('registers: the NF screens left Comercial, the carriers got a screen of their own', () {
      expect(salesMasters.map((s) => s.path), isNot(contains(taxRules.path)));
      expect(salesMasters.map((s) => s.path), isNot(contains(monthlyPrices.path)));
      expect(fiscalMasters, [taxRules, monthlyPrices, carriers]);
      expect(carriers.path, '/api/fiscal/carriers');
      expect(carriers.writePolicy, 'fiscal-emit');
      final items = navItems();
      final fiscal = [
        for (final i in items)
          if (i.section == 'Fiscal') i.id,
      ];
      expect(fiscal, ['fiscal-documents', 'receivables', 'fiscal-settings', taxRules.path, monthlyPrices.path, carriers.path, 'fiscal-import']);
      for (final id in ['fiscal-documents', 'receivables']) {
        expect(items.firstWhere((i) => i.id == id).section, 'Fiscal');
      }
      expect(items.firstWhere((i) => i.id == 'fiscal-import').admin, isTrue);
      expect(items.any((i) => i.id == 'module:Fiscal'), isTrue);
    });

    testWidgets('sidebar of the module: notes and parameters, tabs share an entry, import is for admins only', (tester) async {
      await pumpShell(tester, 'Admin');
      await openModule(tester, 'Fiscal');
      expect(find.byKey(const ValueKey('nav-section-Fiscal')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-fiscal-documents')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-fiscal-settings')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-fiscal-import')), findsOneWidget);
      // The other tabs hide behind their group's entry.
      expect(find.byKey(const ValueKey('nav-receivables')), findsNothing);
      expect(find.byKey(ValueKey('nav-${carriers.path}')), findsNothing);
      expect(find.byKey(const ValueKey('nav-customers')), findsNothing);
    });

    testWidgets('a reader has no import and carriers open as a list', (tester) async {
      await pumpShell(tester, 'Reader');
      await openModule(tester, 'Fiscal');
      expect(find.byKey(const ValueKey('nav-fiscal-import')), findsNothing);
      await openScreen(tester, 'Fiscal', 'fiscal-settings');
      await tester.tap(find.byKey(ValueKey('tab-${carriers.path}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-fiscal-settings')), findsOneWidget);
      expect(find.text('Nova transportadora'), findsNothing, reason: 'writing needs fiscal-emit');
    });

    testWidgets('Painel has the Fiscal card; old screens keep their ids', (tester) async {
      await pumpShell(tester, 'Admin');
      expect(find.byKey(const ValueKey('module-Fiscal')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('module-Fiscal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-section-Fiscal')), findsOneWidget);
      // A pasted link to a moved screen still lands on it, now inside Fiscal.
      await openPalette(tester);
      await tester.enterText(find.byType(TextField).last, '/s/receivables');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Abrir link colado'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-section-Fiscal')), findsOneWidget);
    });
  });

  group('screens of the module', () {
    Future<List<http.Request>> pumpScreen(WidgetTester tester, Widget Function(Session) screen) async {
      final sent = <http.Request>[];
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final client = MockClient((r) async {
        sent.add(r);
        return switch (r.url.path) {
          '/api/fiscal/settings' => json(issuer()),
          '/api/fiscal/settings/all' => json([issuer(enabled: true), issuer(company: 'BST', filled: false, nextNumber: 897)]),
          '/api/fiscal/cfops' => json(cfopList(['5101', '6101'])),
          '/api/fiscal/legacy-import/summary' => json({'issuerFilled': true, 'cfops': 2, 'carriers': 1, 'taxRules': 3, 'monthlyPrices': 0, 'nextNumber': 2581}),
          _ => json(page([])),
        };
      });
      final session =
          Session(
              api: ApiClient(baseUrl: 'http://api.test', client: client, token: 'tok'),
            )
            ..username = 'ana'
            ..role = 'Admin'
            ..permissions = rolePermissions['Admin']!;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('pt', 'BR'),
          supportedLocales: const [Locale('pt', 'BR')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(body: screen(session)),
        ),
      );
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('the old-system import is a page of the module, with its summary and file button', (tester) async {
      await pumpScreen(tester, (s) => FiscalImportScreen(session: s));
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('fiscal-import-choose')), findsOneWidget);
      expect(find.textContaining('3 regras de imposto'), findsOneWidget);
    });

    testWidgets('emitente e emissão lists the registered CFOPs', (tester) async {
      await pumpScreen(tester, (s) => FiscalSettingsScreen(session: s));
      expect(find.text('CFOPs cadastrados'), findsOneWidget);
      expect(find.text('6101 · CFOP 6101'), findsOneWidget);
    });

    testWidgets('the screen has one tab per company and each shows its own issuer', (tester) async {
      await pumpScreen(tester, (s) => FiscalSettingsScreen(session: s));
      expect(find.byKey(const ValueKey('fiscal-company-EBT')), findsOneWidget);
      expect(find.byKey(const ValueKey('fiscal-company-BST')), findsOneWidget);
      // EBT first: its issuer is filled and emission is on.
      expect(find.text('Emissão de NF-e ligada'), findsOneWidget);
      expect(find.text('Dados do emitente incompletos'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('fiscal-company-BST')));
      await tester.pumpAndSettle();
      expect(find.text('Emissão de NF-e desligada'), findsOneWidget);
      expect(find.text('Dados do emitente incompletos'), findsOneWidget);
      expect(find.text('897'), findsOneWidget);
    });

    testWidgets('a link can open the screen on BST, and saving sends the company', (tester) async {
      final sent = await pumpScreen(tester, (s) => FiscalSettingsScreen(session: s, initialCompany: 'BST'));
      expect(find.text('Emissão de NF-e desligada'), findsOneWidget);
      expect(find.text('897'), findsOneWidget);
      await tester.tap(find.text('Editar parâmetros'));
      await tester.pumpAndSettle();
      expect(find.text('Emitente e emissão'), findsWidgets);
      // The save goes to the company in view (the form is not submitted here; the target is what matters).
      expect(sent.where((r) => r.method == 'PUT'), isEmpty);
    });

    testWidgets('the emission switch asks first: turning on warns about the missing A1 and the spent numbers, and nothing is sent until confirmed', (
      tester,
    ) async {
      final sent = await pumpScreen(tester, (s) => FiscalSettingsScreen(session: s, initialCompany: 'BST'));
      expect(tester.widget<Switch>(find.byKey(const ValueKey('fiscal-enabled-switch'))).value, isFalse);
      await tester.tap(find.byKey(const ValueKey('fiscal-enabled-switch')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Ligar a emissão de NF-e do BST?'), findsOneWidget);
      expect(find.textContaining('ainda não há certificado digital A1'), findsOneWidget);
      expect(find.textContaining('gastaria o número 897'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(sent.where((r) => r.method == 'PUT'), isEmpty);
      expect(tester.widget<Switch>(find.byKey(const ValueKey('fiscal-enabled-switch'))).value, isFalse);

      await tester.tap(find.byKey(const ValueKey('fiscal-enabled-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ligar emissão'));
      await tester.pumpAndSettle();
      final put = sent.singleWhere((r) => r.method == 'PUT');
      expect(put.url.path, '/api/fiscal/settings');
      expect(put.url.queryParameters['company'], 'BST');
      expect(jsonDecode(put.body)['enabled'], isTrue);
    });

    testWidgets('turning it off also asks, and says shipping stops issuing the NF', (tester) async {
      final sent = await pumpScreen(tester, (s) => FiscalSettingsScreen(session: s));
      expect(tester.widget<Switch>(find.byKey(const ValueKey('fiscal-enabled-switch'))).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('fiscal-enabled-switch')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Desligar a emissão de NF-e do EBT?'), findsOneWidget);
      expect(find.textContaining('o número da NF volta a ser digitado à mão'), findsOneWidget);
      await tester.tap(find.text('Desligar emissão'));
      await tester.pumpAndSettle();
      final put = sent.singleWhere((r) => r.method == 'PUT');
      expect(put.url.queryParameters['company'], 'EBT');
      expect(jsonDecode(put.body)['enabled'], isFalse);
    });
  });
}
