import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/geospatial_scene.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('large cloud view refines under tile-sized resource pressure', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final controller = SceneController(
      scene: Scene()
        ..renderSettings = RenderSettings(
          hdr: true,
          toneMapping: ToneMapping.agx,
          exposure: 10,
        ),
      camera: PerspectiveCamera(
        position: const Vec3(7400000, 0, 1200000),
        target: const Vec3(6371000, 0, 0),
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 1e9,
      ),
      runtime: android
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
    );
    final profile = GeospatialSceneProfile(
      services: controller.runtime.assetServices,
      clouds: true,
    );
    for (final plugin in profile.plugins) {
      controller.use(plugin);
    }
    controller.use(_TileSizedPressure());
    FrameStats? last;
    var frames = 0;
    final first = Stopwatch();
    final subscription = controller.frameStats.listen((frame) {
      if (!first.isRunning) first.start();
      expectSync(frame.readbackBytes, 0);
      last = frame;
      frames++;
    });
    final records = <Map<String, Object?>>[];
    binding.reportData = {
      'suite': 'geospatial-render-quality',
      'platform': defaultTargetPlatform.name,
      'passed': false,
      'viewports': records,
    };
    Future<void> mount(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, bounds) {
                final ratio = MediaQuery.devicePixelRatioOf(context);
                return SceneView(
                  controller: controller,
                  resolutionScale: geospatialResolutionScale(
                    width: bounds.maxWidth * ratio,
                    height: bounds.maxHeight * ratio,
                  ),
                );
              },
            ),
          ),
        ),
      );
    }

    Future<void> settle(int before) async {
      for (var i = 0; i < 2400; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('${issue.code}: ${issue.message}; ${issue.cause}');
        }
        if (frames > before + 2 &&
            profile.cloudLayer!.controller.history.accumulatedFrames >= 16) {
          return;
        }
      }
      fail('The large cloud view did not complete a Bayer cycle.');
    }

    try {
      for (final size in [const Size(1000, 700), const Size(390, 700)]) {
        final before = frames;
        await mount(size);
        await settle(before);
        final physical = last!.physicalSize;
        expect(math.max(physical.width, physical.height), greaterThan(640));
        expect(physical.width * physical.height, lessThanOrEqualTo(2097152));
        expect(profile.cloudLayer!.controller.history.valid, true);
        records.add({
          'logical': [size.width, size.height],
          'physical': [physical.width, physical.height],
          'backend': (await controller.ready).backend,
          'historyFrames':
              profile.cloudLayer!.controller.history.accumulatedFrames,
          'elapsedMs': first.elapsedMilliseconds,
          'readbackBytes': last!.readbackBytes,
        });
        debugPrint('Geospatial quality: ${records.last}');
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
      await subscription.cancel();
      await tester.binding.setSurfaceSize(null);
    }
    final diagnostics = await MethodChannel(
      android ? 'zyren/android-surfaces' : 'zyren/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics');
    for (final name in [
      'sessions',
      'renderers',
      'retiring',
      'readbackBytes',
      android ? 'surfaces' : 'heldDrawables',
    ]) {
      expect(diagnostics![name], 0, reason: name);
    }
    binding.reportData!['passed'] = true;
    binding.reportData!['diagnostics'] = diagnostics;
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _TileSizedPressure extends ScenePlugin {
  @override
  String get id => 'tile-sized-resource-pressure';
  @override
  Future<void> attach(PluginContext context) async {
    final scope = context.createGpuScope(label: '64 MiB tile-sized pressure');
    await scope.resources.createBuffer(
      BufferDescriptor(size: 64 * 1024 * 1024, usage: {BufferUsage.storage}),
    );
  }
}
