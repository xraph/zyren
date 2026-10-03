import 'dart:io';
import 'package:flutter_zyren/flutter_zyren.dart';
import '../../../packages/flutter_zyren/test/hosted_output_test.dart'
    show NativeViewFake, HostedFactory;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio_example/studio_assets.dart';
import 'package:zyren_studio_example/studio_editor.dart';
import 'package:zyren_studio_example/studio_model_drop.dart';
import 'package:zyren_studio_example/studio_theme.dart';

class _Store implements StudioStore {
  StudioDocument? saved;
  @override
  Future<StudioDocument?> read() async => saved;
  @override
  Future<void> write(StudioDocument value) async {
    saved = value;
  }
}

void main() {
  testWidgets(
    'model drop commits a complete batch and rolls back a failed batch',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('studio-drop-');
      final cache = StudioPipelineAssets(directory);
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = _Store();
      late SceneController controller;
      await tester.pumpWidget(
        MaterialApp(
          theme: studioTheme(Brightness.light),
          home: StudioEditor(
            document: StudioDocument(id: 'drop', title: 'Drop', nodes: []),
            store: store,
            assetResolver: cache,
            saveLocation: '/test/drop.zyren',
            viewportBuilder: (value) {
              controller = value;
              return SceneView(controller: value);
            },
            runtime: SceneRuntime(
              backendFactory: () async => _Backend(),
              nativeViewPresenterFactory: HostedFactory(),
            ),
          ),
        ),
      );
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      expect(
        controller.status.value,
        isA<SceneReady>(),
        reason: controller.status.value is SceneFailed
            ? (controller.status.value as SceneFailed).issue.message
            : '${controller.status.value}',
      );
      expect(
        tester.widget<StudioModelDrop>(find.byType(StudioModelDrop)).enabled,
        isTrue,
      );
      final prefix = Directory.current.path.endsWith('/studio') ? '../../' : '';
      final model = File(
        '${prefix}examples/model_viewer/assets/models/deformation.glb',
      ).absolute.path;
      await tester.runAsync(
        () => tester
            .widget<StudioModelDrop>(find.byType(StudioModelDrop))
            .onFiles([model, model]),
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 250));
      expect(store.saved!.nodes.length, 2);
      expect(store.saved!.assets.length, 2);
      final before = store.saved!.encode();
      await tester.runAsync(
        () => tester
            .widget<StudioModelDrop>(find.byType(StudioModelDrop))
            .onFiles([model, '/invalid.unsupported']),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.textContaining('Import failed:'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 250));
      expect(store.saved!.encode(), before);
      await tester.tap(find.text('Undo'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump(const Duration(milliseconds: 250));
      expect(store.saved!.nodes, isEmpty);
      expect(store.saved!.assets, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(tester.takeException(), isNull);
    },
  );
}

class _Backend extends NativeViewFake {
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'drop-test',
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
