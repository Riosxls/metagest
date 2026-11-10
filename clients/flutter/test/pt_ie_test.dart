import 'package:flutter_test/flutter_test.dart';
import 'package:ebt_engenharia/reports/pt_text.dart';

void main() {
  test('state registration gets the dots of its state', () {
    expect(ptIe('105296060110', 'SP'), '105.296.060.110');
    expect(ptIe('105296060110'), '105.296.060.110');
    expect(ptIe('115.467.772.113', 'sp'), '115.467.772.113');
    expect(ptIe('254123456', 'SC'), '254.123.456');
    expect(ptIe('1234567890', 'PR'), '123.45678-90');
    expect(ptIe('0123456789', 'RS'), '012/3456789');
    expect(ptIe('ISENTO', 'SP'), 'ISENTO');
    expect(ptIe('12345', 'BA'), '12345');
    expect(ptIe(null), '');
  });
}
