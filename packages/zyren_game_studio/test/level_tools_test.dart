import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/zyren_game_studio.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  testWidgets(
    'level templates profiles navigation and rule edits persist in compact panels',
    (tester) async {
      final rules = GameRuleLibrary(),
          authoring = createGameDevelopmentAuthoring();
      final scene = StudioScene(
        StudioDocument(id: 'workspace', title: 'Project', nodes: []),
      );
      final host = StudioEditorHostController(
        services: StudioEditorServices(
          scene: scene,
          commands: StudioCommands(
            scene: scene,
            sessionId: 'test',
            isAllowed: (_) => true,
            isAvailable: () => true,
          ),
          agents: AgentRegistry(grantedScopes: {'studio.edit'}),
          isAvailable: () => true,
          viewportSnapshot: () => {},
          capabilities: () => {},
          applyDocument: scene.apply,
        ),
      );
      host.registerAll([
        GameStudioContribution(authoring).contribution,
        GameLevelStudioContribution(authoring, rules).contribution,
      ]);
      final engine = (await tester.runAsync(
        () => SceneEngine.create(
          scene: scene.scene,
          camera: scene.camera,
          rendererFactory: () async => _Renderer(),
          plugins: [scene.tools],
        ),
      ))!;
      Future<void> show(String panel, double width) async {
        tester.view.physicalSize = Size(width, 760);
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StudioEditorHost(
                controller: host,
                viewport: const SizedBox(),
                workspaceBuilder: (_, panes, _) =>
                    panes.singleWhere((p) => p.id == panel).child,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      try {
        for (final width in [1200.0, 328.0]) {
          await show('game.level', width);
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.text('Use vehicle playground'));
        await tester.pumpAndSettle();
        expect(scene.document.id, 'workspace');
        expect(authoring.entityFor(scene.document, 'vehicle'), isNotNull);
        final tick = find.widgetWithText(TextFormField, 'Tick rate (Hz)');
        await tester.enterText(tick, '30');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(
          GameLevelAuthoring(authoring).profile(scene.document).fixedHz,
          30,
        );
        await tester.tap(find.text('Bake navigation'));
        await tester.pumpAndSettle();
        final bake = GameLevelAuthoring(authoring).navigation(scene.document)!;
        expect(bake.mesh.cells, isNotEmpty);
        expect(bake.isCurrent(scene.document), isTrue);
        final restored = StudioDocument.decode(scene.document.encode());
        expect(
          GameLevelAuthoring(
            authoring,
          ).navigation(restored)!.isCurrent(restored),
          isTrue,
        );
        scene.tools.select(scene.objects['player']);
        await show('game.rules', 328);
        await tester.tap(find.text('Add node'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'interaction'),
          'custom-action',
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(
          GameRuleAuthoring(authoring, rules)
              .read(scene.document, 'player')
              .graph
              .nodes
              .last
              .arguments['interaction'],
          'custom-action',
        );
        expect(tester.takeException(), isNull);
        scene.undo();
        expect(
          GameRuleAuthoring(authoring, rules)
              .read(scene.document, 'player')
              .graph
              .nodes
              .any((n) => n.id == 'node-1'),
          isFalse,
        );
        await show('game.states', 328);
        await tester.tap(find.text('Add state machine'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Add state'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'State ID'),
          'patrol',
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(
          GameStateMachineAuthoring(
            authoring,
            rules,
          ).read(scene.document, 'player').states.keys,
          contains('patrol'),
        );
        await tester.tap(find.text('Add transition'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'count'),
          '1.5',
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(find.text('Enter an integer.'), findsOneWidget);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'count'),
          '2',
        );
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(
          GameStateMachineAuthoring(authoring, rules)
              .read(scene.document, 'player')
              .transitions
              .single
              .arguments['count'],
          2,
        );
        scene.tools.select(scene.objects['vehicle']);
        await show('game.states', 328);
        await tester.tap(find.text('Add state machine'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add transition'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        for (final width in [1200.0, 328.0]) {
          await show('game.states', width);
          expect(tester.takeException(), isNull);
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        await host.close();
        await tester.runAsync(engine.dispose);
        tester.view.reset();
      }
    },
  );
}

class _Renderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'level-layout-test',
    features: {RenderFeatures.indexedMeshes},
    maxDimension: 64,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}
