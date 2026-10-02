import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_interaction_example/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native Metal hover capture and agent action share scene tools', (
    tester,
  ) async {
    final key = GlobalKey<InteractionDemoState>();
    await tester.pumpWidget(MaterialApp(home: InteractionDemo(key: key)));
    final state = key.currentState!;
    for (var i = 0; i < 200 && state.controller.latestFrameStats == null; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(state.controller.status.value, isA<SceneReady>());
    expect(state.controller.latestFrameStats, isNotNull);
    expect(state.controller.latestFrameStats!.readbackBytes, 0);
    expect(
      (state.controller.status.value as SceneReady).info.presentationPath,
      PresentationPath.nativeView,
    );
    final extent = tester.getSize(find.byType(SceneView)),
        origin = tester.getTopLeft(find.byType(SceneView));
    final object = state.objects.first;
    final ndc = state.controller.camera.projectPoint(
      object.position,
      extent.aspectRatio,
    );
    final local = Offset(
      (ndc.x + 1) * extent.width / 2,
      (1 - ndc.y) * extent.height / 2,
    );
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      pointer: 23,
    );
    await mouse.addPointer(location: origin + local);
    await mouse.moveTo(origin + local + const Offset(1, 0));
    await tester.pump();
    expect(state.hovered, 'Orange');
    await mouse.down(origin + local);
    await tester.pump();
    expect(state.interaction.capturedObjects, isNotEmpty);
    final before = object.position;
    await mouse.moveBy(const Offset(30, 10));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(state.interaction.capturedObjects, isEmpty);
    expect(object.position, isNot(before));
    final host = state.agentHost;
    final query = await host.registry.call(
      providerId: 'zyren.viewport',
      instanceId: 'main',
      tool: 'context',
    );
    expect(query.status, AgentStatus.ok);
    expect(query.data['presentedFrame'], isNotNull);
    final provider = host.interactionProvider;
    final undo = await host.registry.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: 'undo',
      expectedRevision: provider.revision,
      idempotencyKey: 'native-undo',
    );
    expect(undo.status, AgentStatus.ok);
    expect(object.position, before);
    final pick = await host.registry.call(
      providerId: 'zyren.viewport',
      instanceId: 'main',
      tool: 'pick',
      arguments: {'x': local.dx, 'y': local.dy},
    );
    expect(pick.status, AgentStatus.ok);
    expect((pick.data['hits'] as List).first['object']['runtimeId'], object.id);
    expect(
      (pick.data['coverage'] as Map)['renderedPixelVisibility'],
      'unknown',
    );

    // Opt-in rendezvous lets an external CLI process exercise the live native
    // host. The credential file stays in this app's temporary directory.
    if (const bool.fromEnvironment('ZYREN_EXTERNAL_MCP_CHECK')) {
      final server = await tester.runAsync(host.startBridge);
      final rendezvous = File(
        '${Directory.systemTemp.path}/zyren-interaction-native-bridge.json',
      );
      final complete = File('${rendezvous.path}.done');
      if (await complete.exists()) await complete.delete();
      await rendezvous.writeAsString(
        jsonEncode({
          'endpoint': server!.endpoint.toString(),
          'token': server.token,
          'point': {'x': local.dx, 'y': local.dy},
          'runtimeId': object.id,
        }),
      );
      // Only the path is logged. Credentials are never copied into test output.
      debugPrint('ZYREN_INTERACTION_BRIDGE_FILE=${rendezvous.path}');
      try {
        for (var i = 0; i < 900 && !await complete.exists(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
        expect(
          await complete.exists(),
          isTrue,
          reason: 'External MCP probe did not complete.',
        );
        expect(jsonDecode(await complete.readAsString())['ok'], isTrue);
        expect(state.tools.selected, same(object));
      } finally {
        if (await rendezvous.exists()) await rendezvous.delete();
        if (await complete.exists()) await complete.delete();
      }
    }
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(
      () => state.controller.whenDisposed.timeout(const Duration(seconds: 20)),
    );
    expect(tester.takeException(), isNull);
  });
}
