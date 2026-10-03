import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:smaller_plugins_lab/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'displayed native configuration, effects, frame context and audio lifecycle',
    (tester) async {
      app.main();
      await tester.pump();
      final state = tester.state<app.SmallerLabState>(
        find.byType(app.SmallerLab),
      );
      Future<void> settleFrame() async {
        for (var i = 0; i < 200; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          if (state.controller.status.value is SceneFailed) {
            fail('${state.controller.status.value}');
          }
          final p = state.host.presented;
          if (p != null &&
              p.sceneRevision == state.scene.revision &&
              p.cameraRevision == state.camera.revision) {
            return;
          }
        }
        fail('Native frame did not correlate with current scene/camera.');
      }

      await settleFrame();
      final ready = state.controller.status.value as SceneReady;
      expect(ready.info.presentationPath, PresentationPath.nativeView);
      final host = state.host;
      final before = host.presented!;
      final hit = await host.registry.call(
        providerId: host.viewportProvider.id,
        instanceId: 'view',
        tool: 'pick',
        arguments: {
          'x': .5,
          'y': .5,
          'coordinateSpace': 'normalized',
          'expectedFrameId': before.id,
        },
      );
      expect(hit.status, AgentStatus.ok);
      expect(
        (hit.data['hits'] as List).first['object']['metadata']['sourceId'],
        'body',
      );
      await tester.tap(find.text('Red'));
      await settleFrame();
      expect(state.configurator.current!.choices['finish'], 'red');
      expect(host.presented!.id, isNot(before.id));
      final stale = await host.registry.call(
        providerId: host.viewportProvider.id,
        instanceId: 'view',
        tool: 'pick',
        arguments: {
          'x': .5,
          'y': .5,
          'coordinateSpace': 'normalized',
          'expectedFrameId': before.id,
        },
      );
      expect(stale.status, AgentStatus.stale);
      final effect = await tester.runAsync(
        () => state.call(host.effectsProvider, 'chain', {
          'smaa': 'low',
          'dithering': true,
        }),
      );
      expect(effect!.status, AgentStatus.ok);
      await settleFrame();
      expect(state.scene.effects.length, 4);
      await tester.tap(find.text('Review overlay'));
      await tester.pump();
      final context = await host.registry.call(
        providerId: host.viewportProvider.id,
        instanceId: 'view',
        tool: 'context',
      );
      expect((context.data['hostState'] as Map)['pointerBlockedByUi'], true);
      await tester.tap(find.text('Close review'));
      await tester.pump();
      await tester.tap(find.byTooltip('Toggle narrow viewport'));
      await tester.pump();
      state.controller.invalidate();
      await settleFrame();
      expect(tester.takeException(), isNull);
      expect(
        (state.controller.input as ViewportInputSource).viewport.width,
        lessThanOrEqualTo(360),
      );
      final audio = state.audio;
      expect(audio, isNotNull, reason: state.audioStatus);
      await tester.runAsync(() async {
        // The macOS driver can launch without foregrounding the window. Drive
        // host lifecycle explicitly; real OS interruptions need device checks.
        await state.audioSession.setForeground(true);
        expect(await state.audioSession.play(), true);
        state.tone!.play(restart: true);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await state.audioSession.setForeground(false);
        final cursor = state.tone!.cursor;
        await Future<void>.delayed(const Duration(milliseconds: 80));
        expect(state.tone!.cursor, cursor);
        await state.audioSession.setForeground(true);
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(state.tone!.cursor, greaterThan(cursor));
        state.tone!.pause();
        await state.audioSession.pause();
      });
      debugPrint(
        'ZYREN_SMALLER_EVIDENCE=${jsonEncode({'platform': Platform.operatingSystem, 'presentation': ready.info.presentationPath.name, 'frame': host.presented!.toJson(), 'audioBackend': audio!.backend, 'humanAudibility': 'unverified', 'effects': state.scene.effects.length, 'narrowWidth': (state.controller.input as ViewportInputSource).viewport.width})}',
      );
      await tester.runAsync(
        () => Future.wait([host.startBridge(), host.startBridge()]),
      );
      final bridgeDirectory = host.bridgeFile!.parent;
      expect(await bridgeDirectory.list().length, 1);
      if (const bool.fromEnvironment('ZYREN_SMALLER_MCP')) {
        final done = File(
          '${bridgeDirectory.path}/zyren-smaller-native-bridge.done',
        );
        if (await done.exists()) await done.delete();
        debugPrint('ZYREN_SMALLER_AWAITING_MCP=${done.path}');
        for (var i = 0; i < 1200 && !await done.exists(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
        expect(
          await done.exists(),
          true,
          reason: 'External MCP and displayed inspection did not finish.',
        );
        if (await done.exists()) await done.delete();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        for (var i = 0; i < 100 && await bridgeDirectory.exists(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await bridgeDirectory.exists(), false);
      });
    },
  );
}
