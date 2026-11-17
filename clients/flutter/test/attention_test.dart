import 'package:ebt_engenharia/widgets/attention.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('the strip is dismissed with the X, stays dismissed, and comes back when there are more problems', (tester) async {
    SharedPreferences.setMockInitialValues({});
    Widget strip(int count) => _app(NoticeStrip(id: 'x', count: count, icon: Icons.error_outline, text: '$count problemas', stripKey: const ValueKey('strip')));

    await tester.pumpWidget(strip(3));
    await tester.pumpAndSettle();
    expect(find.text('3 problemas'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('dismiss-notice-x')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strip')), findsNothing);

    // Same count (a new visit to the screen): still dismissed.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(strip(3));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strip')), findsNothing);
    // Fewer: still dismissed. More: it shows again.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(strip(2));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strip')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(strip(4));
    await tester.pumpAndSettle();
    expect(find.text('4 problemas'), findsOneWidget);
  });

  testWidgets('nothing shows for a count of zero', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(_app(const NoticeStrip(id: 'y', count: 0, icon: Icons.error_outline, text: 'nada', stripKey: ValueKey('strip'))));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('strip')), findsNothing);
  });

  testWidgets('the attention button counts its notices, lists them and opens the one chosen; with none it is not there', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        AttentionButton(
          notices: [
            AttentionNotice(Icons.content_copy_outlined, '7 grupos parecem duplicados', () => opened.add('dup')),
            AttentionNotice(Icons.error_outline, '26 clientes com cadastro incompleto', () => opened.add('fiscal')),
          ],
        ),
      ),
    );
    expect(find.text('2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('attention-button')));
    await tester.pumpAndSettle();
    expect(find.text('7 grupos parecem duplicados'), findsOneWidget);
    await tester.tap(find.text('26 clientes com cadastro incompleto'));
    await tester.pumpAndSettle();
    expect(opened, ['fiscal']);

    await tester.pumpWidget(_app(const AttentionButton(notices: [])));
    expect(find.byKey(const ValueKey('attention-button')), findsNothing);
  });
}
