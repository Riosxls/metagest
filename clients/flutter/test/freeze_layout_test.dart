import 'package:ebt_engenharia/widgets/freeze_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a frozen child is not laid out again when the space changes, and catches up when shown', (tester) async {
    var builds = 0;
    final widths = <double>[];
    // The same widget instance every time, as the Shell now keeps for a hidden page: Flutter then touches the child only when its constraints change.
    final page = LayoutBuilder(
      builder: (context, box) {
        builds++;
        widths.add(box.maxWidth);
        return const SizedBox.expand();
      },
    );
    Widget host(double width, bool frozen) => Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, height: 100, child: FreezeLayout(frozen: frozen, child: page)),
      ),
    );

    await tester.pumpWidget(host(400, false));
    expect(widths.last, 400);
    final before = builds;

    // Hidden: the window grows, the page keeps its 400 and is not built again.
    await tester.pumpWidget(host(500, true));
    expect(builds, before);
    expect(widths.last, 400);

    // Shown again: one layout with the real width.
    await tester.pumpWidget(host(500, false));
    expect(widths.last, 500);
    expect(builds, before + 1);
  });
}
