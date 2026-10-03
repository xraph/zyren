import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_pipeline_lab/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native prepared view, source pick, eviction, miss and disk reload', (
    tester,
  ) async {
    final key = GlobalKey<PipelineLabState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        home: PipelineLab(key: key),
      ),
    );
    final state = key.currentState!;
    Future<void> settle() async {
      for (
        var i = 0;
        i < 300 && (state.busy || state.controller.latestFrameStats == null);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.error, isNull);
      expect(state.busy, isFalse);
      expect(state.controller.status.value, isA<SceneReady>());
      expect(tester.takeException(), isNull);
    }

    Future<void> nextFrame(int before) async {
      for (
        var i = 0;
        i < 300 && (state.controller.latestFrameStats?.frameId ?? -1) <= before;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(state.controller.latestFrameStats!.frameId, greaterThan(before));
    }

    Future<void> visualAction(String label) async {
      final before = state.controller.latestFrameStats?.frameId ?? -1;
      await tester.tap(find.text(label));
      await settle();
      await nextFrame(before);
    }

    await settle();
    final before = state.controller.latestFrameStats?.frameId ?? -1;
    state.controller.invalidate();
    await nextFrame(before);
    final info = (state.controller.status.value as SceneReady).info;
    expect(
      info.presentationPath,
      Platform.isAndroid
          ? PresentationPath.nativeView
          : PresentationPath.sharedTexture,
    );
    expect(state.mesh!.geometry.capture().primitiveCount, 128);
    final metrics = (state.controller.input as ViewportInputSource).viewport;
    final picked = await state.registry.call(
      providerId: state.viewport.id,
      instanceId: 'main',
      tool: 'pick',
      arguments: {'x': metrics.width / 2, 'y': metrics.height / 2},
    );
    expect(picked.status, AgentStatus.ok);
    expect(
      (picked.data['hits'] as List).first['object']['metadata']['sourceId'],
      'part:grid',
    );
    expect(picked.data['presentedFrame'], isNotNull);
    expect(
      (picked.data['hits'] as List).first['renderedPixelVisibility'],
      'unknown',
    );
    if (Platform.isMacOS) {
      final previousSize = tester.view.physicalSize;
      tester.view.physicalSize = Size(
        360 * tester.view.devicePixelRatio,
        720 * tester.view.devicePixelRatio,
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.text('Evict cache'), findsOneWidget);
      tester.view.physicalSize = previousSize;
      await tester.pump(const Duration(milliseconds: 400));
    }
    await visualAction('Show original');
    expect(state.mesh!.geometry.capture().primitiveCount, 512);
    await visualAction('Show LOD');
    await tester.tap(find.text('Evict cache'));
    await settle();
    expect(state.runtime.cache.length, 0);
    expect(state.mesh, isNotNull);
    await visualAction('Reload');
    expect(find.text('No cached bundle'), findsOneWidget);
    expect(state.mesh, isNull);
    await visualAction('Restore bundle');
    expect(state.mesh!.geometry.capture().primitiveCount, 128);
    print(
      'PIPELINE_NATIVE backend=${info.backend} presentation=${info.presentationPath.name} texture=${state.target} '
      'viewport=${metrics.width}x${metrics.height} dpr=${metrics.devicePixelRatio} bundle=${state.current!.version}',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await state.controller.whenDisposed;
  });
}
