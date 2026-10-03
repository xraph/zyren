import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_collaboration_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native shared scene survives offline conflict, undo and camera follow',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('scene-native-test-'),
      );
      final demo = (await tester.runAsync(() => DemoSession.open(directory!)))!;
      Future<void> action(Future<void> Function() body) async {
        await tester.runAsync(() => demo.act(body));
        await tester.pump(const Duration(milliseconds: 100));
        expect(demo.error, isNull);
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: CollaborationDemo(session: demo),
          ),
        );
        for (
          var i = 0;
          i < 200 &&
              (demo.left.latestFrameStats == null ||
                  demo.right.latestFrameStats == null);
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        for (final controller in [demo.left, demo.right]) {
          expect(controller.status.value, isA<SceneReady>());
          expect(controller.latestFrameStats, isNotNull);
          expect(controller.latestFrameStats!.readbackBytes, 0);
          expect(
            (controller.status.value as SceneReady).info.presentationPath,
            PresentationPath.nativeView,
          );
        }
        await action(demo.moveAlice);
        expect(demo.leftBox.position, demo.rightBox.position);
        expect(demo.leftBox.position.x, closeTo(.3, .0001));
        await action(demo.toggleOffline);
        await action(demo.moveAlice);
        expect(demo.queue!.pending, hasLength(1));
        await action(demo.moveBob);
        expect(demo.leftBox.position, isNot(demo.rightBox.position));
        await action(demo.toggleOffline);
        expect(demo.queue!.conflict, isNotNull);
        expect(find.text('Keep mine'), findsOneWidget);
        await action(() async {
          await demo.outbox.keepLocal(
            uniqueId(),
            reviewed: demo.queue!.conflict!,
          );
          await demo.synchronize();
        });
        expect(demo.leftBox.position, demo.rightBox.position);
        expect(demo.leftBox.position.x, closeTo(.6, .0001));
        final provider = demo.agents.provider;
        final undone = await tester.runAsync(
          () => demo.agents.registry.call(
            providerId: provider.id,
            instanceId: 'main',
            tool: 'undo',
            arguments: {'revision': demo.lastAliceRevision!},
            expectedRevision: provider.revision,
            idempotencyKey: 'native-undo',
          ),
        );
        expect(undone!.status, AgentStatus.ok);
        await action(demo.refresh);
        expect(demo.leftBox.position, demo.rightBox.position);
        expect(demo.leftBox.position.x, closeTo(0, .0001));
        await action(demo.followAlice);
        await action(demo.orbitAlice);
        expect(demo.right.camera.position, demo.left.camera.position);
        final view = find.byType(SceneView).first;
        final extent = tester.getSize(view);
        final point = demo.left.camera.projectPoint(
          demo.leftBox.position,
          extent.aspectRatio,
        );
        final local = Offset(
          (point.x + 1) * extent.width / 2,
          (1 - point.y) * extent.height / 2,
        );
        final hit = await tester.runAsync(
          () => demo.agents.registry.call(
            providerId: 'zyren.viewport',
            instanceId: 'main',
            tool: 'pick',
            arguments: {'x': local.dx, 'y': local.dy},
          ),
        );
        expect(hit!.status, AgentStatus.ok);
        expect(
          (hit.data['hits'] as List).first['object']['runtimeId'],
          demo.leftBox.id,
        );
        expect(
          (hit.data['coverage'] as Map)['renderedPixelVisibility'],
          'unknown',
        );
        final context = await tester.runAsync(
          () => demo.agents.registry.call(
            providerId: 'zyren.viewport',
            instanceId: 'main',
            tool: 'context',
          ),
        );
        expect(context!.data['presentedFrame'], isNotNull);
        expect(tester.takeException(), isNull);

        if (const bool.fromEnvironment('ZYREN_EXTERNAL_MCP_CHECK')) {
          final bridge = await tester.runAsync(demo.agents.startBridge);
          final rendezvous = File('${directory!.path}/bridge.json');
          final complete = File('${rendezvous.path}.done');
          await tester.runAsync(
            () => rendezvous.writeAsString(
              jsonEncode({
                'endpoint': bridge!.endpoint.toString(),
                'token': bridge.token,
                'point': {'x': local.dx, 'y': local.dy},
                'runtimeId': demo.leftBox.id,
              }),
            ),
          );
          debugPrint('ZYREN_COLLABORATION_BRIDGE_FILE=${rendezvous.path}');
          for (var i = 0; i < 900 && !complete.existsSync(); i++) {
            await tester.pump(const Duration(milliseconds: 100));
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)),
            );
          }
          expect(
            complete.existsSync(),
            isTrue,
            reason: 'External MCP probe did not finish.',
          );
          expect(jsonDecode(complete.readAsStringSync())['ok'], isTrue);
        }
        // Render the compact layout at a narrow logical width with both native views.
        await tester.binding.setSurfaceSize(const Size(390, 844));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byType(SceneView), findsNWidgets(2));
        expect(tester.takeException(), isNull);
        await tester.binding.setSurfaceSize(null);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
          () => demo.close().timeout(const Duration(seconds: 20)),
        );
        await tester.runAsync(() => directory!.delete(recursive: true));
      }
    },
  );
}
