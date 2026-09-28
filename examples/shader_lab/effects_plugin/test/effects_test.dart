import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';

class UnsupportedBackend implements RenderBackend {
  int frames = 0;
  bool closed = false;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'no effects',
    features: {},
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 4096),
  );
  @override
  Future<FrameOutput> render(FrameSubmission frame) async {
    expect(frame.graph, isNull);
    frames++;
    return ReadbackOutput(
      image: ImageData(pixels: Uint8List(4), size: PhysicalSize(1, 1)),
      stats: FrameStats(
        frameId: frames,
        physicalSize: PhysicalSize(1, 1),
        presentationPath: PresentationPath.readback,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: 0,
        triangles: 0,
        readbackBytes: 4,
        uploadedBytes: 0,
      ),
    );
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

class Consumer extends ScenePlugin {
  @override
  String get id => 'consumer';
  @override
  Set<String> get dependencies => {EffectsPlugin.pluginId};
  late EffectsControls controls;
  @override
  void attach(PluginContext context) {
    controls = context.service(effectsControls);
  }
}

void main() {
  test(
    'options reject nonfinite and out-of-range values before publication',
    () {
      for (final value in [double.nan, double.infinity, -3.0, 3.0]) {
        expect(() => EffectsOptions(exposure: value), throwsArgumentError);
      }
      expect(() => EffectsOptions(saturation: -0.1), throwsArgumentError);
      expect(() => EffectsOptions(saturation: 2.1), throwsArgumentError);
      expect(() => EffectsOptions(vignette: 1.1), throwsArgumentError);
      final options = EffectsOptions(exposure: 1, saturation: .6, vignette: .3);
      final disabled = options.copyWith(enabled: false);
      expect(disabled.enabled, isFalse);
      expect(disabled.exposure, 1);
      expect(disabled.saturation, .6);
      expect(disabled.vignette, .3);
    },
  );
  test(
    'required effects reject unsupported adapters before attachment',
    () async {
      final backend = UnsupportedBackend();
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => backend,
          plugins: [EffectsPlugin()],
        ),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.pluginId,
            'plugin',
            EffectsPlugin.pluginId,
          ),
        ),
      );
      expect(backend.closed, isTrue);
      expect(backend.frames, 0);
    },
  );
  test('explicit bypass publishes typed controls without GPU access', () async {
    final backend = UnsupportedBackend();
    final plugin = EffectsPlugin(unsupported: UnsupportedEffects.bypass);
    final consumer = Consumer();
    var invalidations = 0;
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
      plugins: [consumer, plugin],
      onInvalidate: () {
        invalidations++;
      },
    );
    try {
      expect(consumer.controls, same(plugin));
      expect(plugin.state.availability, EffectsAvailability.unsupported);
      expect(plugin.state.missingFeatures, contains(RenderFeature.frameGraphs));
      consumer.controls.options = EffectsOptions(vignette: .5);
      expect(invalidations, 1);
      await engine.renderFrame(elapsed: Duration.zero, width: 1, height: 1);
      expect(backend.frames, 1);
      expect(plugin.state.graphBuilds, 0);
    } finally {
      await engine.dispose();
    }
    expect(plugin.state.availability, EffectsAvailability.detached);
    plugin.options = EffectsOptions(enabled: false);
    expect(invalidations, 1);
  });
}
