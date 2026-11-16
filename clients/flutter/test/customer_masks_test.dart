import 'package:ebt_engenharia/api.dart';
import 'package:ebt_engenharia/entities.dart';
import 'package:ebt_engenharia/reports/pt_text.dart';
import 'package:ebt_engenharia/screens/customers.dart';
import 'package:ebt_engenharia/widgets/entity_form.dart';
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

  test('the CEP is written 00000-000 as it is typed', () {
    expect(maskZip(''), '');
    expect(maskZip('1332'), '1332');
    expect(maskZip('133242'), '13324-2');
    expect(maskZip('13324240'), '13324-240');
    expect(maskZip('13324-240'), '13324-240');
    expect(maskZip('133242401'), '13324-240');
  });

  test('the phone is written (11) 2914-5677 for a landline and (11) 99999-9999 for a mobile', () {
    expect(maskPhone(''), '');
    expect(maskPhone('1'), '(1');
    expect(maskPhone('11'), '(11');
    expect(maskPhone('1129'), '(11) 29');
    expect(maskPhone('11291456'), '(11) 2914-56');
    expect(maskPhone('1129145677'), '(11) 2914-5677');
    expect(maskPhone('11999999999'), '(11) 99999-9999');
    expect(maskPhone('(11) 2914-5677'), '(11) 2914-5677');
  });

  test('a phone field with several numbers, or a local number without area code, is left as typed', () {
    expect(maskPhone('(11) 2914-5677 / 2682-0000'), '(11) 2914-5677 / 2682-0000');
    expect(maskPhone('2914-5677 ou 2682-0000'), '2914-5677 ou 2682-0000');
    expect(maskPhone('2914-5677'), '2914-5677');
    expect(maskPhone('119999999999'), '119999999999');
  });

  test('the IE follows the punctuation of its state', () {
    expect(ptIe('600005179113', 'SP'), '600.005.179.113');
    expect(ptIe('062307904008', 'MG'), '062307904008');
    expect(ptIe('0623079040081', 'MG'), '062.307.904/0081');
    expect(ptIe('0100482300112', 'AC'), '01.004.823/001-12');
    expect(ptIe('123456789', 'AM'), '12.345.678-9');
    expect(ptIe('12345663', 'BA'), '123456-63');
    expect(ptIe('1234567890', 'PR'), '123.45678-90');
    expect(ptIe('2243658792', 'RS'), '224/3658792');
    expect(ptIe('181001000004', 'PE'), '181001000004');
    expect(ptIe('18100100000049', 'PE'), '18.1.001.0000004-9');
    expect(ptIe('240066281', 'RR'), '24006628-1');
    expect(ptIe('240000009', 'MA'), '240000009');
    expect(ptIe('ISENTO', 'MG'), 'ISENTO');
  });

  test('the IE is punctuated while it is typed, following the UF of the form', () {
    expect(maskIeInput('6000051', 'SP'), '600.005.1');
    expect(maskIeInput('600005179113', 'SP'), '600.005.179.113');
    expect(maskIeInput('1234567', 'PR'), '123.4567');
    expect(maskIeInput('12345678', 'BA'), '123456-78');
    expect(maskIeInput('123456789', 'BA'), '1234567-89');
    expect(maskIeInput('1234567890', 'RS'), '123/4567890');
    expect(maskIeInput('1234567890123', 'RS'), '123/4567890');
    expect(maskIeInput('240000009', 'MA'), '240000009');
    expect(maskIeInput('ISENTO', 'SP'), 'ISENTO');
    // Without a state only a complete SP number is punctuated.
    expect(maskIeInput('6000051'), '6000051');
    expect(maskIeInput('600005179113'), '600.005.179.113');
    expect(maskIe('0623079040081', 'MG'), '062.307.904/0081');
  });

  Future<void> pump(WidgetTester tester, List<FieldSpec> fields, Map<String, dynamic> initial) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EntityFormDialog(api: ApiClient(baseUrl: 'http://api.test'), title: 'x', fields: fields, initial: initial, onSubmit: (_) async => null),
      ),
    ),
  );

  String text(WidgetTester tester, String k) => tester.widget<TextField>(find.byKey(ValueKey('field-$k'))).controller!.text;

  testWidgets('the form opens with the stored digits punctuated, and the IE follows the UF of the same block', (tester) async {
    await pump(
      tester,
      [
        const FieldSpec('company.document', 'CNPJ/CPF', mask: maskDocument),
        const FieldSpec('company.stateRegistration', 'Inscrição estadual', mask: maskIe),
        const FieldSpec('company.uf', 'UF', type: FieldType.choice, choices: {'SP': 'SP', 'MG': 'MG'}),
        const FieldSpec('company.zipCode', 'CEP', mask: maskZip),
        const FieldSpec('company.phone', 'Telefone', mask: maskPhone),
      ],
      {
        'company.document': '56650658000101',
        'company.stateRegistration': '0623079040081',
        'company.uf': 'MG',
        'company.zipCode': '13324240',
        'company.phone': '1129145677',
      },
    );
    expect(text(tester, 'company.document'), '56.650.658/0001-01');
    expect(text(tester, 'company.stateRegistration'), '062.307.904/0081');
    expect(text(tester, 'company.zipCode'), '13324-240');
    expect(text(tester, 'company.phone'), '(11) 2914-5677');
    // Typing a new IE uses the UF of the form (MG here).
    await tester.enterText(find.byKey(const ValueKey('field-company.stateRegistration')), '0623079040082');
    await tester.pump();
    expect(text(tester, 'company.stateRegistration'), '062.307.904/0082');
  });

  testWidgets('typing in the middle of a number keeps the cursor beside the digit just typed', (tester) async {
    await pump(tester, const [FieldSpec('zipCode', 'CEP', mask: maskZip)], {'zipCode': '13324240'});
    final field = find.byKey(const ValueKey('field-zipCode'));
    await tester.tap(field);
    await tester.pump();
    // "133|24-240" gets a 9 typed at the cursor: the raw text is "1339324-240" with the cursor after the 9.
    tester.testTextInput.updateEditingValue(const TextEditingValue(text: '13393324-240', selection: TextSelection.collapsed(offset: 4)));
    await tester.pump();
    final c = tester.widget<TextField>(field).controller!;
    expect(c.text, '13393-324');
    expect(c.selection.baseOffset, 4);
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
