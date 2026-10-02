import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_interaction_example/main.dart';

void main() {
  for (final size in [const Size(1200, 800), const Size(360, 640)]) {
    testWidgets('compact controls fit $size with visible viewport', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: InteractionDemo(
            viewportBuilder: (_) =>
                const ColoredBox(key: Key('viewport'), color: Colors.black),
          ),
        ),
      );
      expect(find.text('Object interaction'), findsOneWidget);
      expect(find.text('Reset'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('viewport'))).height,
        greaterThan(size.height / 2),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Reset'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
