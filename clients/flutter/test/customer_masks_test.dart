import 'package:ebt_engenharia/screens/customers.dart';
import 'package:ebt_engenharia/widgets/record_list.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the document gets its punctuation as it is typed, CPF up to 11 digits and CNPJ after', () {
    expect(maskDocument(''), '');
    expect(maskDocument('123'), '123');
    expect(maskDocument('1234'), '123.4');
    expect(maskDocument('12345678901'), '123.456.789-01');
    expect(maskDocument('566506580001'), '56.650.658/0001');
    expect(maskDocument('56650658000101'), '56.650.658/0001-01');
    expect(maskDocument('56.650.658/0001-01999'), '56.650.658/0001-01');
  });

  test('the IE is written with dots once it has the 12 digits of a São Paulo one, and ISENTO stays', () {
    expect(maskIe('600005179113'), '600.005.179.113');
    expect(maskIe('6000051'), '6000051');
    expect(maskIe('ISENTO'), 'ISENTO');
  });

  testWidgets('a copy button beside the CNPJ copies it with its punctuation', (tester) async {
    String? copied;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: InfoGrid([('CNPJ/CPF', '56.650.658/0001-01'), ('Nome', 'IKS')], copyLabels: {'CNPJ/CPF'}),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('copy-CNPJ/CPF')), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-Nome')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('copy-CNPJ/CPF')));
    await tester.pump();
    expect(copied, '56.650.658/0001-01');
    expect(find.text('CNPJ/CPF copiado'), findsOneWidget);
  });
}
