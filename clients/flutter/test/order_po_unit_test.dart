import 'dart:typed_data';

import 'package:ebt_engenharia/screens/sales_common.dart';
import 'package:ebt_engenharia/screens/sales_orders.dart';
import 'package:ebt_engenharia/screens/sales_quotes.dart';
import 'package:ebt_engenharia/widgets/pipeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'sales_more_support.dart';

Future<void> _pickCustomer(WidgetTester tester) async {
  await tapKey(tester, 'quote-customer');
  await tester.tap(find.text('BTS Tubos').last);
  await tester.pumpAndSettle();
}

Future<void> _addItem(WidgetTester tester) async {
  await tapKey(tester, 'add-line');
  await tester.tap(find.text('TB-25 · Tubo 25,4 x 1,5').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const ValueKey('field-quantity')), '10');
  await tester.enterText(find.byKey(const ValueKey('field-leadTimeDays')), '15');
  await tester.tap(find.widgetWithText(FilledButton, 'Adicionar item').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the unit chosen beside the quantity travels with the item as spec.saleUnit', (tester) async {
    final f = MoreFake();
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true));
    await _pickCustomer(tester);
    await tapKey(tester, 'add-line');
    await tester.tap(find.text('TB-25 · Tubo 25,4 x 1,5').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pç'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('field-quantity')), '10');
    await tester.enterText(find.byKey(const ValueKey('field-leadTimeDays')), '15');
    await tester.tap(find.widgetWithText(FilledButton, 'Adicionar item').last);
    await tester.pumpAndSettle();
    expect(find.text('10 PÇ'), findsOneWidget); // the list says what the quantity counts
    await tapKey(tester, 'quote-save');
    final line = (f.body(f.last('POST', '/api/sales/orders'))['lines'] as List).single as Map<String, dynamic>;
    expect((line['spec'] as Map)['saleUnit'], 'PC');
    expect(line.containsKey('saleUnit'), isFalse);
  });

  testWidgets('the purchase order chosen on a new order is uploaded right after the order is saved', (tester) async {
    final f = MoreFake();
    f.overrides['POST /api/sales/orders/9/request-file'] = (r) => jsonResp({...f.order, 'id': 9, 'requestFileName': 'po-cliente.pdf', 'requestFileSize': 3});
    final old = requestFilePicker;
    requestFilePicker = () async => (name: 'po-cliente.pdf', bytes: Uint8List.fromList([1, 2, 3]));
    addTearDown(() => requestFilePicker = old);
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true));
    await _pickCustomer(tester);
    await _addItem(tester);
    expect(find.byKey(const ValueKey('order-po-chip')), findsNothing);
    await tapKey(tester, 'order-attach-po');
    expect(find.byKey(const ValueKey('order-po-chip')), findsOneWidget);
    expect(find.text('po-cliente.pdf'), findsOneWidget);
    expect(f.called('POST', '/api/sales/orders/9/request-file'), isFalse); // nothing is sent before the order exists
    await tapKey(tester, 'quote-save');
    expect(f.called('POST', '/api/sales/orders'), isTrue);
    expect(f.called('POST', '/api/sales/orders/9/request-file'), isTrue);
  });

  testWidgets('removing the chosen file before saving sends nothing', (tester) async {
    final f = MoreFake();
    final old = requestFilePicker;
    requestFilePicker = () async => (name: 'po-cliente.pdf', bytes: Uint8List.fromList([1, 2, 3]));
    addTearDown(() => requestFilePicker = old);
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true));
    await _pickCustomer(tester);
    await _addItem(tester);
    await tapKey(tester, 'order-attach-po');
    await tester.tap(find.byTooltip('Remover anexo'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('order-po-chip')), findsNothing);
    await tapKey(tester, 'quote-save');
    expect(f.called('POST', '/api/sales/orders/9/request-file'), isFalse);
  });

  group('order typed without a quote', () {
    MoreFake direct() => MoreFake()..order['quoteId'] = null;

    testWidgets('the path starts at the purchase order and the file can be attached on the order page', (tester) async {
      final f = direct();
      f.overrides['POST /api/sales/orders/9/request-file'] = (r) {
        f.order
          ..['requestFileName'] = 'po-cliente.pdf'
          ..['requestFileSize'] = 3;
        return jsonResp(f.order);
      };
      final old = requestFilePicker;
      requestFilePicker = () async => (name: 'po-cliente.pdf', bytes: Uint8List.fromList([1, 2, 3]));
      addTearDown(() => requestFilePicker = old);
      await pumpMore(tester, f, (s) => SalesOrderScreen(session: s, id: 9));
      // Orçamento, Enviada and Aprovada never happened: only the five steps from the purchase order on are drawn.
      expect(find.byKey(const ValueKey('path-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('path-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('path-5')), findsNothing);
      expect(find.textContaining('Aprovada pelo cliente'), findsNothing);
      expect(find.text('Nenhum arquivo anexado (PDF, imagem ou texto).'), findsOneWidget);
      await tapKey(tester, 'order-po-attach');
      expect(f.called('POST', '/api/sales/orders/9/request-file'), isTrue);
      expect(find.textContaining('po-cliente.pdf'), findsWidgets);
      expect(find.byKey(const ValueKey('order-po-print')), findsOneWidget);
    });

    testWidgets('an order that came from a quote keeps the whole path and no attach section', (tester) async {
      final f = MoreFake();
      await pumpMore(tester, f, (s) => SalesOrderScreen(session: s, id: 9));
      expect(find.byKey(const ValueKey('path-7')), findsOneWidget);
      expect(find.byKey(const ValueKey('order-po-attach')), findsNothing);
    });
  });

  testWidgets('the step in progress is drawn in the amber of the theme, not in the primary blue', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: const Scaffold(
          body: SizedBox(width: 1400, child: StagePath(steps: flowSteps, current: 4)),
        ),
      ),
    );
    final box = tester.widget<Container>(find.byKey(const ValueKey('path-4')));
    final ctx = tester.element(find.byKey(const ValueKey('path-4')));
    expect(box.color, toneAccent(ctx, Tone.warning));
    expect(box.color, isNot(Theme.of(ctx).colorScheme.primary));
  });
}
