import 'dart:typed_data';

import 'package:ebt_engenharia/screens/deliveries.dart';
import 'package:ebt_engenharia/screens/sales_common.dart';
import 'package:ebt_engenharia/screens/sales_orders.dart';
import 'package:ebt_engenharia/screens/sales_quotes.dart';
import 'package:ebt_engenharia/widgets/pipeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

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

  testWidgets('on a wide screen the order form is a grid: rows end on the same edge and the purchase order field is not squeezed', (tester) async {
    final f = MoreFake();
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true), size: const Size(1800, 900));
    final origin = tester.getRect(find.byKey(const ValueKey('order-origin')));
    final notes = tester.getRect(find.widgetWithText(TextField, 'Observações'));
    final customer = tester.getRect(find.byKey(const ValueKey('quote-customer')));
    expect(origin.right, closeTo(notes.right, 0.5)); // second and third rows end together
    expect(notes.left, greaterThan(customer.left)); // the notes start after the salesperson
    final po = tester.getRect(find.widgetWithText(TextField, 'Pedido de compra do cliente'));
    expect(po.width, greaterThan(300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the person responsible for a new order is the signed-in profile and cannot be edited', (tester) async {
    final f = MoreFake();
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true));
    final field = tester.widget<TextField>(find.byKey(const ValueKey('order-salesperson')));
    expect(field.readOnly, isTrue);
    expect(field.controller!.text, 'ana');
  });

  testWidgets('when the file cannot be sent the user is told, and can try again', (tester) async {
    final f = MoreFake();
    var attempts = 0;
    f.overrides['POST /api/sales/orders/9/request-file'] = (r) {
      attempts++;
      if (attempts == 1) return http.Response('{"message":"falhou"}', 500, headers: {'content-type': 'application/json'});
      return jsonResp({...f.order, 'id': 9, 'requestFileName': 'po-cliente.pdf', 'requestFileSize': 3});
    };
    final old = requestFilePicker;
    requestFilePicker = () async => (name: 'po-cliente.pdf', bytes: Uint8List.fromList([1, 2, 3]));
    addTearDown(() => requestFilePicker = old);
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true));
    await _pickCustomer(tester);
    await _addItem(tester);
    await tapKey(tester, 'order-attach-po');
    await tapKey(tester, 'quote-save');
    expect(find.byKey(const ValueKey('po-upload-failed')), findsOneWidget); // not a message that fades away
    expect(f.where('POST', '/api/sales/orders').length, 1);
    await tapKey(tester, 'po-upload-retry');
    expect(attempts, 2);
    expect(find.byKey(const ValueKey('po-upload-failed')), findsNothing);
    expect(f.where('POST', '/api/sales/orders').length, 1); // retrying never types the order twice
  });

  testWidgets('the footer keeps the totals on the left and Salvar pedido on the right edge, with what is missing beside it', (tester) async {
    final f = MoreFake();
    await pumpMore(tester, f, (s) => QuoteEditorScreen(session: s, asOrder: true), size: const Size(1800, 900));
    final save = tester.getRect(find.byKey(const ValueKey('quote-save')));
    final missing = tester.getRect(find.byKey(const ValueKey('quote-missing')));
    final total = tester.getRect(find.byKey(const ValueKey('quote-estimate')));
    expect(save.right, closeTo(1800 - 16, 1)); // pinned to the right edge
    expect(missing.right, lessThan(save.left));
    expect(total.left, lessThan(300));
    expect(tester.getRect(find.byKey(const ValueKey('order-attach-po'))).top, lessThan(500)); // the form is still on screen: the footer does not take the page
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
      // Once a file is attached the section is gone and the print panel no longer asks for it.
      expect(find.byKey(const ValueKey('order-po-attach')), findsNothing);
      expect(find.text('Nenhum arquivo anexado (PDF, imagem ou texto).'), findsNothing);
      expect(find.textContaining('Anexe o pedido de compra do cliente na seção'), findsNothing);
      expect(find.text('po-cliente.pdf'), findsWidgets);
    });

    testWidgets('an order that came from a quote keeps the whole path and no attach section', (tester) async {
      final f = MoreFake();
      await pumpMore(tester, f, (s) => SalesOrderScreen(session: s, id: 9));
      expect(find.byKey(const ValueKey('path-7')), findsOneWidget);
      expect(find.byKey(const ValueKey('order-po-attach')), findsNothing);
    });
  });

  group('delivery page path', () {
    testWidgets('a delivery of an order typed without a quote shows the same five steps as the order', (tester) async {
      final f = MoreFake();
      f.deliveryExtra = {'orderQuoteId': null};
      await pumpMore(tester, f, (s) => DeliveryScreen(session: s, id: 15));
      expect(find.byKey(const ValueKey('path-4')), findsOneWidget);
      expect(find.byKey(const ValueKey('path-5')), findsNothing);
      expect(find.textContaining('Aprovada pelo cliente'), findsNothing);
    });

    testWidgets('a delivery of an order that came from a quote keeps the eight steps', (tester) async {
      final f = MoreFake();
      f.deliveryExtra = {'orderQuoteId': 5};
      await pumpMore(tester, f, (s) => DeliveryScreen(session: s, id: 15));
      expect(find.byKey(const ValueKey('path-7')), findsOneWidget);
    });
  });

  testWidgets('the step in progress is drawn in yellow, not in the primary blue', (tester) async {
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
    expect(box.color, stepInProgress);
    expect(box.color, isNot(Theme.of(ctx).colorScheme.primary));
  });
}
