import 'package:ebt_engenharia/entities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a tube is shown with the same sizes whatever its old name looked like', () {
    expect(LookupSpec.display({'code': '080.090.60', 'name': 'TUBO-C 08,00 X 0,90 X 6000 MM', 'kind': 'Part', 'ncm': '73063010', 'diameterMm': 8.0, 'thicknessMm': 0.9, 'lengthMm': 6000.0}), '080.090.60 · Ø 8 × 0,9 × 6000 mm');
    expect(LookupSpec.display({'code': '127.140.61', 'name': 'TUBO-C 12,70 X 1,40 X 618,50MM', 'kind': 'Part', 'ncm': '1', 'diameterMm': 12.7, 'thicknessMm': 1.4, 'lengthMm': 618.5}), '127.140.61 · Ø 12,7 × 1,4 × 618,5 mm');
    expect(LookupSpec.display({'code': '140.150.00', 'name': 'TUBO-C 14,00 X 1,50 X ROLO', 'kind': 'Part', 'ncm': '1', 'diameterMm': 14, 'thicknessMm': 1.5, 'lengthMm': 1000}), '140.150.00 · Ø 14 × 1,5 · rolo');
    expect(LookupSpec.display({'code': 'R1', 'name': 'x', 'kind': 'Part', 'ncm': '1', 'widthMm': 20, 'heightMm': 30, 'thicknessMm': 1.5, 'lengthMm': 6000}), 'R1 · 20 × 30 × 1,5 × 6000 mm');
  });

  test('records without sizes keep code and name', () {
    expect(LookupSpec.display({'code': 'C1', 'name': 'Componente', 'kind': 'Component', 'ncm': '1'}), 'C1 · Componente');
    expect(LookupSpec.display({'code': 'P1', 'name': 'Prazo 28'}), 'P1 · Prazo 28');
  });
}
