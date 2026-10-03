import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:zyren/zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/zyren_game_studio.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'component_authoring_test.dart' show authoring, plain;

StudioEditorHostController host(
  GameAuthoring edits, {
  Set<String> scopes = const {'studio.edit'},
}) {
  final document = edits.addComponent(
    plain(),
    'actor',
    GameComponentRecord('test.link', 1, {'target': 'actor', 'value': 1}),
  );
  final scene = StudioScene(document);
  return StudioEditorHostController(
    services: StudioEditorServices(
      scene: scene,
      commands: StudioCommands(
        scene: scene,
        sessionId: 'game-editor',
        isAllowed: (_) => true,
        isAvailable: () => true,
      ),
      agents: AgentRegistry(grantedScopes: scopes),
      isAvailable: () => true,
      viewportSnapshot: () => {},
      capabilities: () => {'native.metal'},
      applyDocument: scene.apply,
    ),
  );
}

void main() {
  testWidgets(
    'collection editor adds typed inventory entries and wheel pairs atomically',
    (tester) async {
      Object? items = <String, Object?>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: GameComponentField(
                  key: const ValueKey('inventory'),
                  descriptor: const GameFieldDescriptor(
                    'items',
                    'Items',
                    GameFieldKind.json,
                  ),
                  value: items,
                  origin: GameFieldOrigin.authored,
                  entities: const [],
                  enabled: true,
                  onChanged: (value) => setState(() => items = value),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Items'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add entry'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextFormField, 'name'), 'key');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'count'),
        '1.5',
      );
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a valid count.'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextFormField, 'count'), '3');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(items, {'key': 3});
      expect(tester.takeException(), isNull);
      final base = VehicleDefinition(
        wheels: [
          for (final z in [-1.0, 1.0])
            for (final x in [-.7, .7])
              WheelDefinition(
                id: 'wheel$x$z',
                mount: Vec3(x, 0, z),
                steering: z > 0,
              ),
        ],
      ).toJson();
      Object? wheels = base['wheels'];
      var edits = 0;
      final template = WheelDefinition(
        id: 'middle',
        mount: const Vec3(.7, 0, 0),
      ).toJson();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SingleChildScrollView(
                child: GameComponentField(
                  key: const ValueKey('vehicle'),
                  descriptor: GameFieldDescriptor(
                    'wheels',
                    'Wheels',
                    GameFieldKind.json,
                    entryTemplate: template,
                    entryBatchSize: 2,
                  ),
                  value: wheels,
                  origin: GameFieldOrigin.authored,
                  entities: const [],
                  enabled: true,
                  onChanged: (value) {
                    VehicleDefinition.fromJson({...base, 'wheels': value});
                    setState(() {
                      wheels = value;
                      edits++;
                    });
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Wheels'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add wheel pair'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(wheels as List, hasLength(6));
      expect(edits, 1);
      await tester.tap(find.byTooltip('Remove wheel pair').last);
      await tester.pumpAndSettle();
      expect(wheels as List, hasLength(4));
      expect(edits, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'compact inspector edits through history at desktop and narrow widths',
    (tester) async {
      final edits = authoring(), controller = host(authoring());
      final engine = (await tester.runAsync(
        () => SceneEngine.create(
          scene: controller.services.scene.scene,
          camera: controller.services.scene.camera,
          rendererFactory: () async => _Renderer(),
          plugins: [controller.services.scene.tools],
        ),
      ))!;
      controller.services.scene.tools.select(
        controller.services.scene.objects['actor'],
      );
      final registration = controller.register(
        GameStudioContribution(edits).contribution,
      );
      try {
        for (final width in [1200.0, 328.0]) {
          tester.view.reset();
          tester.view.physicalSize = Size(width, 760);
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: StudioEditorInspectorSections(controller: controller),
                ),
              ),
            ),
          );
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.text('Game components'), findsOneWidget);
          final field = find.widgetWithText(TextFormField, 'Value (m)');
          expect(field, findsOneWidget);
          await tester.enterText(field, '4');
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect(
            edits
                .entityFor(controller.services.scene.document, 'actor')!
                .components
                .single
                .data['value'],
            4,
          );
          controller.services.scene.undo();
          controller.refresh();
          await tester.pump();
          expect(
            edits
                .entityFor(controller.services.scene.document, 'actor')!
                .components
                .single
                .data['value'],
            1,
          );
        }
        registration.dispose();
        await tester.pump();
        expect(find.text('Game components'), findsNothing);
        expect(controller.panelIds, isEmpty);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await controller.close();
        await tester.runAsync(engine.dispose);
        tester.view.reset();
      }
    },
  );
  test(
    'agent edits share authoring checks revisions scopes and undo',
    () async {
      final edits = authoring(), controller = host(authoring());
      controller.register(GameStudioContribution(edits).contribution);
      final scene = controller.services.scene,
          agents = controller.services.agents;
      final before = scene.document.encode();
      final changed = await agents.call(
        providerId: 'zyren.game-authoring',
        instanceId: 'game',
        tool: 'set_fields',
        arguments: {
          'nodeId': 'actor',
          'component': 'test.link',
          'fields': {'value': 4},
        },
        expectedRevision: scene.revision,
        idempotencyKey: 'edit1',
      );
      expect(changed.status, AgentStatus.ok);
      expect(
        edits
            .entityFor(scene.document, 'actor')!
            .components
            .single
            .data['value'],
        4,
      );
      scene.undo();
      expect(scene.document.encode(), before);
      final invalid = await agents.call(
        providerId: 'zyren.game-authoring',
        instanceId: 'game',
        tool: 'set_fields',
        arguments: {
          'nodeId': 'actor',
          'component': 'test.link',
          'fields': {'value': 99},
        },
        expectedRevision: scene.revision,
        idempotencyKey: 'edit2',
      );
      expect(invalid.status, AgentStatus.invalid);
      expect(scene.document.encode(), before);
      await controller.close();
      final deniedHost = host(authoring(), scopes: {});
      deniedHost.register(GameStudioContribution(edits).contribution);
      final denied = await deniedHost.services.agents.call(
        providerId: 'zyren.game-authoring',
        instanceId: 'game',
        tool: 'set_fields',
        arguments: {
          'nodeId': 'actor',
          'component': 'test.link',
          'fields': {'value': 4},
        },
        expectedRevision: deniedHost.services.scene.revision,
        idempotencyKey: 'denied',
      );
      expect(denied.status, AgentStatus.denied);
      await deniedHost.close();
    },
  );
}

class _Renderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'editor-test',
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
