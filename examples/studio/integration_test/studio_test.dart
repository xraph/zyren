import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/io.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/fixture.dart';
import 'package:zyren_studio_example/studio_editor.dart';

void main() {
  const externalMcp = bool.fromEnvironment('STUDIO_NATIVE_MCP');
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native pick, authorized edit, undo, file reload and narrow layout',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-studio-native-',
      );
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final store = FileStudioStore(
        file: File('${directory.path}/scene.json'),
        documentId: 'studio-scene',
      );
      final key = GlobalKey<StudioEditorState>();
      final width = ValueNotifier<double>(1000);
      addTearDown(width.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<double>(
            valueListenable: width,
            builder: (_, value, _) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: value,
                child: StudioEditor(
                  key: key,
                  document: starterScene(),
                  store: store,
                  saveLocation: store.file.path,
                  enableAgentTransport: externalMcp,
                  agentScopes: const {
                    'studio.select',
                    'studio.edit',
                    'timeline.playback',
                  },
                ),
              ),
            ),
          ),
        ),
      );
      SceneController controller() =>
          tester.widget<SceneView>(find.byType(SceneView)).controller!;
      Future<void> until(FutureOr<bool> Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controller().status.value is SceneFailed) {
            fail('${controller().status.value}');
          }
          if (await condition()) return;
        }
        fail(
          'Studio did not reach the expected state: ${controller().status.value}',
        );
      }

      await until(() => controller().latestFrameStats != null);
      expect(
        (await controller().ready).presentationPath,
        PresentationPath.nativeView,
      );
      expect(controller().latestFrameStats!.readbackBytes, 0);
      final view = find.byType(SceneView);
      final size = tester.getSize(view);
      final projected = controller().camera.projectPoint(
        Vec3.zero,
        size.aspectRatio,
      );
      final point = Offset(
        (projected.x + 1) * size.width / 2,
        (1 - projected.y) * size.height / 2,
      );
      await tester.tapAt(tester.getTopLeft(view) + point);
      await until(
        () => find
            .byKey(const ValueKey('selection-position'))
            .evaluate()
            .isNotEmpty,
      );
      final state = key.currentState!;
      Future<AgentResult> screen() => state.agents.call(
        providerId: 'zyren.studio',
        instanceId: state.agentProvider.instanceId,
        tool: 'state',
      );
      Future<AgentResult> playback(
        String action,
        int index, [
        double? seconds,
      ]) {
        final provider = (state.agents.discover()['providers'] as List)
            .firstWhere((entry) => entry['providerId'] == 'zyren.timeline');
        return state.agents.call(
          providerId: 'zyren.timeline',
          instanceId: 'camera-preview',
          tool: 'playback',
          expectedRevision: provider['revision'] as int,
          idempotencyKey: 'native-$action-$index',
          arguments: {'action': action, 'seconds': ?seconds},
        );
      }

      final arrow = descendants(
        controller().scene,
      ).lastWhere((object) => object.name == 'translate x');
      final matrix = world(arrow).storage;
      final gripWorld = Vec3(
        matrix[0] * 1.425 + matrix[12],
        matrix[1] * 1.425 + matrix[13],
        matrix[2] * 1.425 + matrix[14],
      );
      final grip = controller().camera.projectPoint(
        gripWorld,
        size.aspectRatio,
      );
      final gesture = await tester.startGesture(
        tester.getTopLeft(view) +
            Offset(
              (grip.x + 1) * size.width / 2,
              (1 - grip.y) * size.height / 2,
            ),
        kind: PointerDeviceKind.mouse,
      );
      await until(
        () async =>
            ((await screen()).data['screen'] as Map)['transformDragActive'] ==
            true,
      );
      final blockedDrag = await state.agents.call(
        providerId: 'zyren.studio',
        instanceId: state.agentProvider.instanceId,
        tool: 'transform',
        expectedRevision: state.agentProvider.revision,
        idempotencyKey: 'drag-blocked',
        arguments: {
          'targetId': 'block',
          'position': [5, 0, 0],
        },
      );
      expect(blockedDrag.status, AgentStatus.unavailable);
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.up();
      await until(
        () =>
            state.agentProvider.commands.scene.objects['block']!.position.x !=
            0,
      );
      await tester.tap(find.text('Undo'));
      await until(
        () =>
            state.agentProvider.commands.scene.objects['block']!.position ==
            Vec3.zero,
      );

      expect((await playback('pause', 0)).status, AgentStatus.ok);
      expect(((await screen()).data['screen'] as Map)['previewActive'], false);
      final camera = StudioCamera.capture(
        controller().camera as PerspectiveCamera,
      ).toJson();
      for (var index = 0; index < 3; index++) {
        final presented = (await screen()).data['screen'] as Map;
        expect((await playback('seek', index, 1.5)).status, AgentStatus.ok);
        await until(
          () async =>
              ((await screen()).data['screen'] as Map)['presentedFrame']['id'] >
              presented['presentedFrame']['id'],
        );
        final preview = (await screen()).data['screen'] as Map;
        expect(preview['previewActive'], true);
        expect(preview['timelineMicroseconds'], 1500000);
        expect(
          preview['presentedFrame']['id'],
          greaterThan(presented['presentedFrame']['id']),
        );
        final blocked = await state.agents.call(
          providerId: 'zyren.studio',
          instanceId: state.agentProvider.instanceId,
          tool: 'transform',
          expectedRevision: state.agentProvider.revision,
          idempotencyKey: 'preview-blocked-$index',
          arguments: {
            'targetId': 'block',
            'position': [5, 0, 0],
          },
        );
        expect(blocked.status, AgentStatus.unavailable);
        if (index == 2) {
          expect((await playback('play', index)).status, AgentStatus.ok);
          await until(
            () async =>
                ((await screen()).data['screen']
                    as Map)['timelineMicroseconds'] >
                1500000,
          );
        }
        await tester.tap(find.text('Stop preview'));
        await until(() => find.text('Preview camera').evaluate().isNotEmpty);
        expect(
          StudioCamera.capture(
            controller().camera as PerspectiveCamera,
          ).toJson(),
          camera,
        );
        final timeline = await state.agents.call(
          providerId: 'zyren.timeline',
          instanceId: 'camera-preview',
          tool: 'inspect',
        );
        expect(timeline.data['playing'], false);
      }
      var previousFrame = -1;
      var quietPumps = 0;
      await until(() {
        final frame = controller().latestFrameStats!.frameId;
        quietPumps = frame == previousFrame ? quietPumps + 1 : 0;
        previousFrame = frame;
        return quietPumps == 4;
      });
      final idleFrame = controller().latestFrameStats!.frameId;
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller().latestFrameStats!.frameId, idleFrame);
      final picked = await state.agents.call(
        providerId: 'zyren.viewport',
        instanceId: 'main',
        tool: 'pick',
        arguments: {'x': point.dx, 'y': point.dy, 'limit': 32},
      );
      expect(picked.status, AgentStatus.ok);
      expect(picked.data['frameCorrelation'], 'unknown');
      expect(
        (picked.data['hits'] as List).any(
          (hit) =>
              hit['object']['metadata']['properties']['studio.nodeId'] ==
              'block',
        ),
        isTrue,
      );
      if (externalMcp) {
        final completion = File('${directory.path}/mcp-complete');
        debugPrint(
          'ZYREN_STUDIO_NATIVE_READY ${jsonEncode({
            'point': {'x': point.dx, 'y': point.dy},
            'completionPath': completion.path,
          })}',
        );
        await until(completion.existsSync);
        expect(await completion.readAsString(), 'ok');
      } else {
        final changed = await state.agents.call(
          providerId: 'zyren.studio',
          instanceId: state.agentProvider.instanceId,
          tool: 'transform',
          expectedRevision: state.agentProvider.revision,
          idempotencyKey: 'native-move',
          arguments: {
            'targetId': 'block',
            'position': [.25, 0, 0],
          },
        );
        expect(changed.status, AgentStatus.ok);
      }
      await until(() => find.textContaining('X 0.25').evaluate().isNotEmpty);
      await tester.tap(find.text('Undo'));
      await until(() => find.textContaining('X 0.00').evaluate().isNotEmpty);
      await tester.tap(find.text('Redo'));
      await until(() => find.textContaining('X 0.25').evaluate().isNotEmpty);
      await tester.tap(find.text('Save'));
      await until(() => find.text('Scene saved').evaluate().isNotEmpty);
      expect(
        (await store.read())!.nodes
            .firstWhere((node) => node.id == 'block')
            .position
            .x,
        .25,
      );
      await tester.tap(find.text('X +0.25'));
      await until(() => find.textContaining('X 0.50').evaluate().isNotEmpty);
      await tester.tap(find.text('Reload'));
      await tester.pump(const Duration(milliseconds: 250));
      final blocked = await state.agents.call(
        providerId: 'zyren.studio',
        instanceId: state.agentProvider.instanceId,
        tool: 'state',
      );
      expect((blocked.data['screen'] as Map)['blockingOverlays'], isNotEmpty);
      final retiredController = controller();
      final retiredRegistry = state.agents;
      final retiredInstance = state.agentProvider.instanceId;
      await tester.tap(find.text('Reload saved'));
      await until(
        () =>
            find.text('Saved scene reloaded').evaluate().isNotEmpty &&
            controller().latestFrameStats != null,
      );
      await retiredController.whenDisposed.timeout(const Duration(seconds: 10));
      expect(state.agentProvider.instanceId, isNot(retiredInstance));
      expect(retiredRegistry.discover, throwsStateError);
      final loaded = controller().scene.children.first.children.first.children
          .firstWhere((object) => object.name == 'Block');
      expect(loaded.position.x, .25);
      width.value = 396;
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getSize(find.byType(SceneView)).width, 396);
      expect(tester.takeException(), isNull);
      final narrow = await state.agents.call(
        providerId: 'zyren.studio',
        instanceId: state.agentProvider.instanceId,
        tool: 'state',
      );
      expect((narrow.data['screen'] as Map)['logicalRect']['width'], 396);
      final finalController = controller();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 250));
      await finalController.whenDisposed;
    },
  );
}

Iterable<Object3D> descendants(Object3D object) sync* {
  for (final child in object.children) {
    yield child;
    yield* descendants(child);
  }
}

Mat4 world(Object3D object) => object.parent == null
    ? object.localMatrix
    : world(object.parent!) * object.localMatrix;
