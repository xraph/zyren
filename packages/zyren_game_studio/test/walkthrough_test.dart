import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_game_studio/ai.dart';

void main() {
  testWidgets(
    'all four registered tours start and resolve live anchors at all widths',
    (tester) async {
      final tours = GameAiWalkthroughs();
      try {
        for (final width in [1440.0, 1024.0, 396.0, 328.0]) {
          tester.view.physicalSize = Size(width, 960);
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            MaterialApp(
              home: OnboardingProvider(
                walkthroughs: tours.registrations,
                child: MediaQuery(
                  data: MediaQueryData(
                    size: Size(width, 960),
                    textScaler: const TextScaler.linear(2),
                  ),
                  child: Scaffold(
                    body: Builder(
                      builder: (context) => SingleChildScrollView(
                        child: Column(
                          children: [
                            for (final row in [
                              (tours.start, 'studio.game.start'),
                              (tours.play, 'studio.game.play'),
                              (tours.perception, 'studio.ai.perception'),
                              (tours.training, 'studio.ai.train'),
                            ])
                              TextButton(
                                key: row.$1,
                                onPressed: () => OnboardingProvider.of(
                                  context,
                                ).start(context, row.$2),
                                child: Text(row.$2),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final id in tours.registrations.keys) {
            await tester.ensureVisible(find.text(id));
            await tester.tap(find.text(id));
            await tester.pumpAndSettle();
            expect(find.text('1 / 1'), findsOneWidget);
            expect(
              find.text('This step is unavailable on the current page.'),
              findsNothing,
            );
            await tester.tap(find.text('Finish tour'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        tester.view.reset();
      }
    },
  );
}
