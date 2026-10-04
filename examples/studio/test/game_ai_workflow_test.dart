import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_game_studio/play.dart';
import 'package:zyren_game_studio/ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/studio_assets.dart';
import 'package:zyren_studio_example/studio_editor.dart';
import 'package:zyren_studio_example/studio_theme.dart';
import '../../../packages/flutter_zyren/test/hosted_output_test.dart'
    show NativeViewFake, HostedFactory;
import 'studio_editor_test.dart' show MemoryStore;

StudioDocument _document() {
  final authoring = createGameAiDevelopmentAuthoring();
  var doc = GameTemplate(
    GameTemplateKind.exploration,
    authoring,
  ).create(projectId: 'ai-studio').document;
  doc = doc.copyWith(
    nodes: [
      ...doc.nodes,
      StudioNode(
        id: 'guard',
        label: 'Guard',
        position: Vec3(0, 1.5, 3),
        size: Vec3(.6, 1.8, .6),
        color: 0x8866bb,
      ),
    ],
  );
  doc = GameLevelAuthoring(authoring).bindCollider(
    doc,
    'guard',
    GameColliderDefinition(
      shape: GameColliderShape.capsule,
      motion: GameBodyMotion.kinematic,
    ),
  );
  doc = authoring.addComponent(
    doc,
    'guard',
    authoring.descriptors['game.character']!.create(),
  );
  doc = authoring.addComponent(
    doc,
    'guard',
    GameComponentRecord('game.ai', 1, {
      'profile': 'guard',
      'brain': 'scripted',
    }),
  );
  return GameLevelAuthoring(
    authoring,
  ).setProfile(doc, GameBuildProfile(id: 'native', fixedHz: 50));
}

final class _Backend extends NativeViewFake {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'AI editor presentation fixture',
    features: RenderFeature.values.toSet(),
    limits: DeviceLimits(
      maxTextureDimension2D: 256,
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

Future<void> _settleNative(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

void main() {
  testWidgets(
    'actual Studio imports accepted files, persists opaque pins and reopens them for export',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final temp = Directory.systemTemp.createTempSync('studio-ai-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final assets = StudioPipelineAssets(Directory('${temp.path}/cache'));
      final store = MemoryStore();
      final rendering = SceneRuntime(
        backendFactory: () async => _Backend(),
        nativeViewPresenterFactory: HostedFactory(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(Brightness.dark),
          home: StudioEditor(
            document: _document(),
            store: store,
            assetResolver: assets,
            saveLocation: '${temp.path}/scene.zyren',
            agentScopes: const {
              'studio.edit',
              'studio.select',
              'game.build',
              'ai.inspect',
              'training.inspect',
            },
            runtime: rendering,
            viewportBuilder: (c) => SceneView(controller: c),
          ),
        ),
      );
      await _settleNative(tester);
      var state = tester.state<StudioEditorState>(find.byType(StudioEditor));
      final workspace = state.gameWorkspace!;
      expect(workspace.ai.canTrain, isFalse);
      await tester.runAsync(
        () => workspace.ai.importLocalArtifact(
          '../game_lab/models/guard',
          MlCancellationToken(),
        ),
      );
      expect(workspace.ai.candidate!.accepted, isTrue);
      expect(workspace.ai.activeModelHash, isNull);
      state.editorHost.services.scene.tools.select(
        state.editorHost.services.scene.objects['guard'],
      );
      await tester.runAsync(workspace.ai.activate);
      expect(
        workspace.ai.activeModelHash,
        workspace.ai.candidate!.contract.model.sha256,
      );
      final activeHash = workspace.ai.activeModelHash;
      await tester.runAsync(
        () => workspace.ai.importLocalArtifact(
          '../game_lab/models/vehicle',
          MlCancellationToken(),
        ),
      );
      expect(workspace.ai.candidate!.accepted, isTrue);
      expect(workspace.preparationDiagnostics!.residentModels, 2);
      expect(workspace.preparationDiagnostics!.leaseReferences, 0);
      await tester.runAsync(
        () => expectLater(workspace.ai.activate(), throwsStateError),
      );
      expect(workspace.ai.activeModelHash, activeHash);
      var document = state.editorHost.services.scene.capture();
      expect(document.assets, isEmpty);
      final pin = workspace.modelPins(document).values.single;
      expect(
        (await tester.runAsync(
          () => assets.cache.get(pin.bundleVersion),
        ))!.resources,
        hasLength(9),
      );
      await tester.runAsync(() => assets.retainPins([document]));
      expect(
        (await tester.runAsync(
          assets.cache.inspect,
        ))!.singleWhere((e) => e.version == pin.bundleVersion).pinned,
        isTrue,
      );
      final save = tester.widget<TextButton>(
        find.ancestor(of: find.text('Save'), matching: find.byType(TextButton)),
      );
      await tester.runAsync(() async {
        save.onPressed!();
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await _settleNative(tester);
      for (var i = 0; i < 30; i++) {
        final reload = tester.widget<TextButton>(
          find.ancestor(
            of: find.text('Reload'),
            matching: find.byType(TextButton),
          ),
        );
        if (reload.onPressed != null) break;
        await _settleNative(tester);
      }
      expect(
        tester
            .widget<TextButton>(
              find.ancestor(
                of: find.text('Reload'),
                matching: find.byType(TextButton),
              ),
            )
            .onPressed,
        isNotNull,
      );
      expect(store.saved, isNotNull);
      await _settleNative(tester);
      await tester.tap(find.text('Reload'));
      for (var i = 0; i < 30; i++) {
        final current = tester
            .state<StudioEditorState>(find.byType(StudioEditor))
            .gameWorkspace;
        if (current != null && !identical(current, workspace)) break;
        await _settleNative(tester);
      }
      state = tester.state<StudioEditorState>(find.byType(StudioEditor));
      document = state.editorHost.services.scene.capture();
      final reopened = state.gameWorkspace!;
      expect(
        reopened,
        isNot(same(workspace)),
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? '')
            .where(
              (t) =>
                  t.contains('Reload') ||
                  t.contains('Save') ||
                  t.contains('failed'),
            )
            .join(' | '),
      );
      expect(reopened.modelPins(document).values.single.encode(), pin.encode());
      for (var i = 0; i < 30 && reopened.validation(document).isNotEmpty; i++) {
        await _settleNative(tester);
      }
      expect(reopened.validation(document), isEmpty, reason: reopened.ai.error);
      final authoring = reopened.authoring;
      final result = await tester.runAsync(
        () =>
            GameProjectCompiler(
              registry: authoring.registry,
              assets: assets.library,
            ).compile(
              documents: [document],
              startupLevel: authoring.expanded(document).levelId,
              profile: GameLevelAuthoring(authoring).profile(document),
              models: reopened.modelPins(document),
            ),
      );
      expect(result!.status, GameBuildStatus.ready);
      final offline = PipelineBundle.decode(result.artifact!.bundle.encode());
      expect(
        offline.resource('model.${pin.sha256}.bundle.json').bytes,
        isNotEmpty,
      );
      expect(
        offline.resource('model.${pin.sha256}.actor.onnx').digest,
        pin.sha256,
      );
      final project = CompiledGameProject.decode(
        utf8.decode(offline.resource('game.recipe').bytes),
        authoring.registry,
      );
      expect(project.fixedHz, 50);
      expect(project.project.modelReferences, hasLength(1));
      await tester.runAsync(() => state.editorHost.startPlay('game.play'));
      await _settleNative(tester);
      final learned = state.editorHost.activePlaySession! as GamePlaySession;
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() async {
          learned.simulation!.step();
          await reopened.activeAi!.flush();
        });
      }
      await tester.pump();
      expect(reopened.ai.diagnostic!['modelFailure'], isNull);
      expect(reopened.activeAi!.completedDecisions, greaterThan(0));
      expect(
        reopened.activeAi!.observation(reopened.ai.selectedActor!),
        isNotNull,
      );
      expect(
        find.byType(GameObservationOverlay, skipOffstage: false),
        findsOneWidget,
      );
      await tester.runAsync(state.editorHost.stopPlay);
      expect(reopened.ai.actors, isEmpty);
      final corruptFolder = Directory('${temp.path}/corrupt')..createSync();
      for (final file in Directory(
        '../game_lab/models/guard',
      ).listSync().whereType<File>()) {
        file.copySync('${corruptFolder.path}/${file.uri.pathSegments.last}');
      }
      final corrupt = File('${corruptFolder.path}/actor.onnx');
      final bytes = corrupt.readAsBytesSync()..[0] ^= 1;
      corrupt.writeAsBytesSync(bytes);
      await tester.runAsync(
        () => expectLater(
          reopened.ai.importLocalArtifact(
            corruptFolder.path,
            MlCancellationToken(),
          ),
          throwsFormatException,
        ),
      );
      expect(
        reopened
            .modelPins(state.editorHost.services.scene.capture())
            .values
            .single
            .encode(),
        pin.encode(),
      );
      await tester.pumpWidget(const SizedBox());
      await _settleNative(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actual play exposes scripted NPC knowledge and clears it before stop',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final rendering = SceneRuntime(
        backendFactory: () async => _Backend(),
        nativeViewPresenterFactory: HostedFactory(),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(Brightness.light),
          home: StudioEditor(
            document: _document(),
            store: MemoryStore(),
            saveLocation: '/tmp/ai-play.zyren',
            runtime: rendering,
            agentScopes: const {
              'ai.inspect',
              'studio.edit',
              'studio.select',
              'training.inspect',
            },
            viewportBuilder: (c) => SceneView(controller: c),
          ),
        ),
      );
      await _settleNative(tester);
      final state = tester.state<StudioEditorState>(find.byType(StudioEditor)),
          owner = state.gameWorkspace!;
      await tester.runAsync(() => state.editorHost.startPlay('game.play'));
      await _settleNative(tester);
      final play = state.editorHost.activePlaySession! as GamePlaySession;
      final physics = play.world!, models = play.models!;
      play.pause();
      play.step();
      await tester.pump();
      expect(owner.ai.actors.single.id, 'guard');
      expect(owner.ai.diagnostic!['brain'], 'scripted');
      expect(
        owner.ai.diagnostic!['knowledge'],
        'Historical permitted observations',
      );
      expect(owner.ai.sensors, hasLength(1));
      expect(owner.historicalObservation(owner.ai.selectedActor!), isNotNull);
      expect(
        find.byType(GameObservationOverlay, skipOffstage: false),
        findsOneWidget,
      );
      if (Platform.environment['RUN_NATIVE_GPU'] == '1') {
        owner.rendering = const SceneRuntime();
        final beforeTick = play.tick;
        await tester.runAsync(owner.captureCamera);
        expect(play.tick, beforeTick);
        expect(play.isPaused, isTrue);
        final camera = owner.ai.cameras.values.single;
        expect(camera.receipt.tick, beforeTick);
        expect(camera.receipt.depth, isNotNull);
        expect(camera.receipt.image.pixels.length, 84 * 84 * 4);
      }
      await tester.runAsync(state.editorHost.stopPlay);
      expect(owner.ai.actors, isEmpty);
      expect(owner.ai.diagnostic, isNull);
      expect(owner.ai.sensors, isEmpty);
      expect(owner.ai.cameras, isEmpty);
      expect(physics.isClosed, isTrue);
      expect(
        (await tester.runAsync(
          () => models.worker.diagnostics(),
        ))!.liveSessions,
        0,
      );
      await tester.pumpWidget(const SizedBox());
      await _settleNative(tester);
      expect(tester.takeException(), isNull);
    },
  );
}
