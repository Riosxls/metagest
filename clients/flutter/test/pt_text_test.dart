import 'package:ebt_engenharia/reports/pt_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('company names from the old system get case and accents', () {
    expect(ptText('METALURGICA FORMIGARI LTDA.'), 'Metalúrgica Formigari Ltda.');
    expect(ptText('INDUSTRIA METALURGICA SETE DE SETEMBRO LTDA'), 'Indústria Metalúrgica Sete de Setembro Ltda.');
    expect(ptText('SOLUCOES EM ACO USIMINAS S.A'), 'Soluções em Aço Usiminas S.A');
    expect(ptText('IND E COM DE AUTO PECAS RONIL LTDA .'), 'Ind. e Com. de Auto Peças Ronil Ltda.');
    expect(ptText('LBA LINHA BRANCA E AUTOMOTIVA LTDA'), 'LBA Linha Branca e Automotiva Ltda.');
  });

  test('streets and cities', () {
    expect(ptText('AV PAPA JOAO XXIII'), 'Av. Papa João XXIII');
    expect(ptText('RODOVIA INDIO TIBIRICA'), 'Rodovia Índio Tibiriçá');
    expect(ptText('RIBEIRAO PIRES'), 'Ribeirão Pires');
    expect(ptText('MAUA'), 'Mauá');
    expect(ptText('SAO BERNARDO DO CAMPO'), 'São Bernardo do Campo');
    expect(ptStreet('AV PAPA JOAO XXIII', '3417'), 'Av. Papa João XXIII, 3417');
  });

  test('text typed by hand keeps its capitals', () {
    expect(ptText('Rua caraguatatuba'), 'Rua caraguatatuba');
    expect(ptText('Metalúrgica Formigari'), 'Metalúrgica Formigari');
    expect(ptText('Embu das Artes'), 'Embu das Artes');
  });

  test('material and numbers stay as they are', () {
    expect(ptText('STKM 11A SAE 1008'), 'STKM 11A SAE 1008');
    expect(ptText(''), '');
    expect(ptText(null), '');
  });

  test('contact, zip, phone and e-mail', () {
    expect(ptText('RAFAEL'), 'Rafael');
    expect(ptZip('09370901'), '09370-901');
    expect(ptPhone('1145436054'), '(11) 4543-6054');
    expect(ptPhone('11945436054'), '(11) 94543-6054');
    expect(ptEmail('RAFAEL@METALURGICA.COM.BR'), 'rafael@metalurgica.com.br');
  });
}
