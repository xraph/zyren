import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/scene.dart';
import 'package:zyren_game_studio/export_io.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio_example/studio_editor.dart';
import 'package:zyren_studio_example/studio_assets.dart';
import 'package:zyren_studio_example/studio_game.dart';
import 'package:zyren_studio_example/studio_theme.dart';
import '../../../packages/flutter_zyren/test/hosted_output_test.dart'
    show NativeViewFake, HostedFactory;
import 'studio_editor_test.dart' show MemoryStore;

void main() {
  testWidgets(
    'an edit prepared at a stale scene revision cannot overwrite a newer edit',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync('game-edit-race-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final authoring = createGameDevelopmentAuthoring();
      final template = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'editor-race').document;
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(Brightness.dark),
          home: StudioEditor(
            document: template,
            store: MemoryStore(),
            saveLocation: '/test/race.zyren',
            assetResolver: StudioPipelineAssets(directory),
            viewportBuilder: (_) => const SizedBox(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final state = tester.state<StudioEditorState>(find.byType(StudioEditor));
      final services = state.editorHost.services;
      final before = services.scene.capture();
      final first = authoring.setFields(
        before,
        nodeId: 'player',
        component: 'game.character',
        fields: {'maxSpeed': 2.5},
      );
      final second = authoring.setFields(
        before,
        nodeId: 'player',
        component: 'game.character',
        fields: {'maxSpeed': 3.5},
      );
      await tester.runAsync(() async {
        // Both edits enter asset preparation at the same revision.
        final accepted = Future<void>.sync(() => services.applyDocument(first));
        final rejected = expectLater(
          Future<void>.sync(() => services.applyDocument(second)),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'reason',
              contains('scene changed'),
            ),
          ),
        );
        await accepted;
        await rejected;
      });
      expect(services.scene.capture().encode(), first.encode());
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual editor persists a component edit and exports its reopened revision',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final directory = Directory.systemTemp.createTempSync(
        'game-editor-workflow-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final output = File('${directory.path}/edited.zygame');
      final store = MemoryStore();
      final authoring = createGameDevelopmentAuthoring();
      final template = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'editor-export').document;
      final runtime = SceneRuntime(
        backendFactory: () async => _Backend(),
        nativeViewPresenterFactory: HostedFactory(),
      );
      final published = Completer<void>();
      late SceneController controller;
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(Brightness.dark),
          home: StudioEditor(
            document: template,
            store: store,
            saveLocation: '/test/edited.zyren',
            runtime: runtime,
            agentScopes: const {'studio.edit', 'studio.select', 'game.build'},
            editorContributions: studioGameContributions(
              runtime: runtime,
              publishGame: (bundle, token, check) async {
                await GameFilePublisher(output).publish(bundle, token, check);
                published.complete();
              },
            ),
            viewportBuilder: (value) {
              controller = value;
              return SceneView(controller: value);
            },
          ),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(controller.status.value, isA<SceneReady>());
      var state = tester.state<StudioEditorState>(find.byType(StudioEditor));
      final edited = await tester.runAsync(
        () => state.agents.call(
          providerId: 'zyren.game-authoring',
          instanceId: template.id,
          tool: 'set_fields',
          expectedRevision: state.editorHost.services.scene.revision,
          idempotencyKey: 'player-speed',
          arguments: {
            'nodeId': 'player',
            'component': 'game.character',
            'fields': {'maxSpeed': 2.5},
          },
        ),
      );
      expect(edited!.status, AgentStatus.ok, reason: edited.message);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(store.saved, isNotNull);
      final saved = store.saved!.encode();
      await tester.tap(find.text('Reload'));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      state = tester.state<StudioEditorState>(find.byType(StudioEditor));
      expect(state.editorHost.services.scene.capture().encode(), saved);
      await tester.runAsync(
        () => state.editorHost.executeCommand('game.export'),
      );
      for (var i = 0; i < 40 && !published.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(published.isCompleted, isTrue);
      expect(tester.takeException(), isNull);
      final offline = PipelineBundle.decode(output.readAsBytesSync());
      final project = CompiledGameProject.decode(
        utf8.decode(offline.resource('game.recipe').bytes),
        authoring.registry,
      );
      final player = project.project.levels.single.entities.singleWhere(
        (e) => e.id == 'player',
      );
      expect(
        player.components
            .singleWhere((c) => c.type == 'game.character')
            .data['maxSpeed'],
        2.5,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      final scene = await tester.runAsync(() => GameRuntimeScene.load(project));
      expect(scene!.objects.containsKey('player'), isTrue);
      await tester.runAsync(scene.close);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Backend extends NativeViewFake {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'game-editor-presentation-fixture',
    features: RenderFeature.values.toSet(),
    limits: DeviceLimits(
      maxTextureDimension2D: 64,
      maxGeometryBytes: 10000000,
      maxPunctualLights: 32,
      maxHemisphereLights: 8,
      maxAreaLights: 8,
      maxJoints: 256,
      maxMorphTargets: 32,
      maxInstances: 1024,
    ),
  );
}
