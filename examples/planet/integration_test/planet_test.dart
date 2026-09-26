import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native viewport renders, responds to controls and fits narrow windows',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 760));
      await tester.pumpWidget(const PlanetApp());
      Future<void> waitForFrame() async {
        for (var attempt = 0; attempt < 120; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(RawImage).evaluate().isNotEmpty &&
              tester.widget<RawImage>(find.byType(RawImage)).image != null) {
            return;
          }
        }
        fail('Native viewport did not produce an image.');
      }

      await waitForFrame();
      expect(find.text('The native renderer could not start'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Tokyo'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Tokyo'))
            .selected,
        isTrue,
      );
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text('Sydney'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(null);
    },
  );
}
