import 'package:doener_app/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dragging across the icons rates as it goes', (tester) async {
    var value = 0.0;
    final changes = <double>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, setState) => DoenerRating(
              value: value,
              size: 40,
              onChanged: (v) => setState(() {
                value = v;
                changes.add(v);
              }),
            ),
          ),
        ),
      ),
    ));

    final rect = tester.getRect(find.byType(DoenerRating));
    final cell = rect.width / 5;
    Offset at(double cells) => rect.centerLeft + Offset(cell * cells, 0);
    final gesture = await tester.startGesture(at(0.1));
    await gesture.moveTo(at(2.75));
    await tester.pump();
    expect(value, 3);
    await gesture.moveTo(at(4.9));
    await tester.pump();
    expect(value, 5);
    await gesture.moveTo(at(0.1));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(value, 0.5);
    expect(changes, [3, 5, 0.5]);

    await tester.tapAt(at(2.75));
    await tester.pumpAndSettle();
    expect(value, 3);
    expect(changes.last, 3);
  });
}
