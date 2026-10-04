import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_game_studio/ai.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_studio_example/studio_editor.dart';
import 'package:zyren_studio_example/studio_theme.dart';
import 'package:zyren_studio_example/studio_workspace.dart';
import 'studio_editor_test.dart' show MemoryStore;

void main() {
  testWidgets(
    'actual editor reveals and starts all four game AI tours across widths and themes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final authoring = createGameAiDevelopmentAuthoring();
      final document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'tours').document;
      for (final brightness in Brightness.values) {
        for (final width in [1440.0, 1024.0, 396.0, 328.0]) {
          tester.view.physicalSize = Size(width, 1100);
          await tester.pumpWidget(
            MaterialApp(
              theme: studioTheme(brightness),
              home: MediaQuery(
                data: MediaQueryData(
                  size: Size(width, 1100),
                  textScaler: const TextScaler.linear(2),
                ),
                child: StudioEditor(
                  key: ValueKey('$brightness/$width'),
                  document: document,
                  store: MemoryStore(),
                  saveLocation: '/tmp/tour.zyren',
                  agentScopes: const {'ai.inspect', 'training.inspect'},
                  viewportBuilder: (_) => const SizedBox(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final context = tester.element(find.byType(StudioWorkspace));
          final onboarding = OnboardingProvider.of(context);
          for (final id in [
            'studio.game.start',
            'studio.game.play',
            'studio.ai.perception',
            'studio.ai.train',
          ]) {
            final closed = onboarding.start(context, id);
            await tester.pumpAndSettle();
            expect(
              find.text('1 / 1'),
              findsOneWidget,
              reason: '$brightness/$width/$id',
            );
            expect(
              find.textContaining('unavailable on the current page'),
              findsNothing,
            );
            expect(find.textContaining('not laid out'), findsNothing);
            await tester.tap(find.text('Finish tour'));
            await tester.pumpAndSettle();
            await closed;
            expect(
              tester.takeException(),
              isNull,
              reason: '$brightness/$width/$id',
            );
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        }
      }
    },
  );
}
