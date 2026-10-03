import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_game_studio/export.dart';
import 'package:zyren_game_studio/export_ui.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

void main() {
  testWidgets(
    'export controls keep path capabilities and actions visible across widths and themes',
    (tester) async {
      for (final width in [1200.0, 328.0]) {
        for (final brightness in Brightness.values) {
          tester.view.physicalSize = Size(width, 600);
          tester.view.devicePixelRatio = 1;
          final authoring = createGameDevelopmentAuthoring();
          final doc = GameTemplate(
            GameTemplateKind.exploration,
            authoring,
          ).create(projectId: 'panel').document;
          var granted = false, published = false;
          final commands = GameBuildCommands(
            compiler: GameProjectCompiler(
              registry: authoring.registry,
              assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
            ),
            documents: () => [doc],
            revision: () => 7,
            startupLevel: () => 'main',
            profile: () => GameLevelAuthoring(authoring).profile(doc),
            allows: (_) => granted,
            isAvailable: () => true,
            outputLabel: '/host/exports/offline/game.zygame',
            publish: (_, token, check) async {
              check();
              published = true;
            },
          );
          Widget view() => MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(body: GameBuildPanel(commands: commands)),
          );
          await tester.pumpWidget(view());
          expect(find.text('Export access required'), findsOneWidget);
          expect(
            find.text('/host/exports/offline/game.zygame'),
            findsOneWidget,
          );
          expect(find.textContaining('Requires:'), findsOneWidget);
          expect(commands.jobs, isEmpty);
          granted = true;
          await tester.pumpWidget(view());
          await tester.tap(find.text('Export'));
          await tester.runAsync(() => commands.jobs.single.done);
          await tester.pump();
          expect(published, isTrue);
          expect(find.text('build-1: succeeded'), findsOneWidget);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(view());
          await tester.tap(find.text('Export'));
          expect(commands.jobs, hasLength(2));
          await tester.runAsync(() => commands.jobs.last.done);
          await tester.pump();
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await commands.close();
        }
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
