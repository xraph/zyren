import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:shader_lab/shader_lab.dart';

class Consumer extends ScenePlugin {
  @override
  String get id => 'consumer';
  @override
  Set<String> get dependencies => {'shader-lab'};
  late ShaderLabControls controls;
  @override
  void attach(PluginContext context) {
    controls = context.service(shaderLabControls);
  }
}

void main() {
  test(
    'required effect features fail before attachment on an unsupported renderer',
    () async {
      final renderer = UnsupportedRenderer();
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => renderer,
          plugins: [ShaderLabPlugin()],
        ),
        throwsA(isA<SceneException>()),
      );
      expect(renderer.closed, isTrue);
    },
  );
  test(
    'independent effect package composes, updates and unregisters through public APIs',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()
        ..background = const Color3(.25, 0, 0)
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      final consumer = Consumer();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [consumer, ShaderLabPlugin()],
      );
      try {
        final first = await engine.render(
          elapsed: Duration.zero,
          width: 24,
          height: 24,
        );
        await consumer.controls.setGain(4);
        final bright = await engine.render(
          elapsed: const Duration(seconds: 1),
          width: 48,
          height: 32,
        );
        expect(bright.pixels[0], greaterThan(first.pixels[0] + 20));
        expect(scene.effects, hasLength(2));
        expect(
          () => consumer.controls.setGain(double.nan),
          throwsArgumentError,
        );
      } finally {
        await engine.dispose();
      }
      expect(scene.effects, isEmpty);
      await expectLater(consumer.controls.setGain(1), throwsStateError);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}

class UnsupportedRenderer implements SceneRenderer {
  bool closed = false;
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'unsupported',
    features: {},
    maxDimension: 128,
  );
  @override
  Future<void> dispose() async {
    closed = true;
  }

  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) => throw UnimplementedError();
}
