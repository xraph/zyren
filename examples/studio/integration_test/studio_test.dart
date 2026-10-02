import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/io.dart';
import 'package:zyren_studio_example/fixture.dart';
import 'package:zyren_studio_example/studio_editor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native pick, authorized edit, undo, file reload and narrow layout',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-studio-native-',
      );
      final store = FileStudioStore(
        file: File('${directory.path}/scene.json'),
        documentId: 'studio-scene',
      );
      final key = GlobalKey<StudioEditorState>();
      final width = ValueNotifier<double>(1000);
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
                  agentScopes: const {'studio.select', 'studio.edit'},
                ),
              ),
            ),
          ),
        ),
      );
      SceneController controller() =>
          tester.widget<SceneView>(find.byType(SceneView)).controller!;
      Future<void> until(bool Function() condition) async {
        for (var i = 0; i < 400; i++) {
          await tester.pump(const Duration(milliseconds: 25));
          if (controller().status.value is SceneFailed) {
            fail('${controller().status.value}');
          }
          if (condition()) return;
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
      await tester.tap(find.text('Reload saved'));
      await until(
        () =>
            find.text('Saved scene reloaded').evaluate().isNotEmpty &&
            controller().latestFrameStats != null,
      );
      final loaded = controller().scene.children.first.children.first.children
          .firstWhere((object) => object.name == 'Block');
      expect(loaded.position.x, .25);
      width.value = 396;
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getSize(find.byType(SceneView)).width, 396);
      expect(tester.takeException(), isNull);
      final screen = await state.agents.call(
        providerId: 'zyren.studio',
        instanceId: state.agentProvider.instanceId,
        tool: 'state',
      );
      expect((screen.data['screen'] as Map)['logicalRect']['width'], 396);
      final finalController = controller();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 250));
      await finalController.whenDisposed;
      width.dispose();
      await directory.delete(recursive: true);
    },
  );
}
