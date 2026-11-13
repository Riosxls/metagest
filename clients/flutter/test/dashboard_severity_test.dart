import 'package:ebt_engenharia/screens/dashboard.dart';
import 'package:ebt_engenharia/widgets/dash.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers to complete are pending and sort after what is late, in the bell too', () {
    final alerts = [
      DashAlert('Engenharia', Icons.block, 'Produtos bloqueados', 238, 'products', null, () {}),
      DashAlert('Comercial', Icons.event_busy, 'Pedidos atrasados', 1, 'sales-orders', null, () {}),
      DashAlert('Comercial', Icons.error_outline, 'Clientes: cadastro incompleto p/ NF', 26, 'customers', null, () {}),
      DashAlert('PCP', Icons.schedule, 'OFs atrasadas', 1, 'production-orders', null, () {}),
    ];
    expect(alerts.map((a) => a.pending), [true, false, true, false]);
    // urgent first, then the pending ones, each in its own order
    expect(bellAlerts(alerts).map((a) => a.label), ['Pedidos atrasados', 'OFs atrasadas', 'Produtos bloqueados', 'Clientes: cadastro incompleto p/ NF']);
  });

  testWidgets('an urgent tile says urgente, a pending one says pendência', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(width: 260, height: 112, child: DashTile(icon: Icons.event_busy, label: 'Pedidos atrasados', value: '1', alert: true, hint: 'urgente', onTap: () {})),
              SizedBox(width: 260, height: 112, child: DashTile(icon: Icons.block, label: 'Produtos bloqueados', value: '238', pending: true, hint: 'pendência', onTap: () {})),
            ],
          ),
        ),
      ),
    );
    expect(find.text('urgente'), findsOneWidget);
    expect(find.text('pendência'), findsOneWidget);
  });
}
