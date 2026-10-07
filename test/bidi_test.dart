import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replylikeme/widgets/bidi.dart';
import 'package:replylikeme/widgets/compose_field.dart';

void main() {
  group('directionOf', () {
    test('Hebrew and Arabic read right to left', () {
      expect(directionOf('מה קורה?'), TextDirection.rtl);
      expect(directionOf('مرحبا'), TextDirection.rtl);
    });

    test('the first letter decides, past emoji, numbers and marks', () {
      expect(directionOf('😂 123 חחח ok'), TextDirection.rtl);
      expect(directionOf('ok, כן'), TextDirection.ltr);
      expect(directionOf('"שלום"'), TextDirection.rtl);
    });

    test('no letters at all keeps the fallback', () {
      expect(directionOf('😂 123'), TextDirection.ltr);
      expect(directionOf('', fallback: TextDirection.rtl), TextDirection.rtl);
    });
  });

  testWidgets('a field turns right to left as Hebrew is typed', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ComposeField(controller: controller, hint: 'hint'),
        ),
      ),
    );
    TextDirection fieldDirection() =>
        Directionality.of(tester.element(find.byType(EditableText)));
    expect(fieldDirection(), TextDirection.ltr);
    await tester.enterText(find.byType(TextField), 'שלום');
    await tester.pump();
    expect(fieldDirection(), TextDirection.rtl);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(fieldDirection(), TextDirection.ltr);
  });

  testWidgets('a Hebrew bubble lays out right to left', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Material(child: SendableBubble(text: 'שלום, מה שלומך?')),
      ),
    );
    final text = tester.widget<Text>(find.text('שלום, מה שלומך?'));
    expect(text.textDirection, TextDirection.rtl);
  });
}
