import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';
import 'effects_test.dart' show UnsupportedBackend;

class Device implements GraphDevice {
  final authors = <Object>{}, graphs = <Object>{}, shaders = <Object>{};
  bool reject = false;
  Completer<void>? gate;
  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) async {
    final key = Object();
    authors.add(key);
    return key;
  }

  @override
  Future<Object> createTexture(TextureDescriptor descriptor) async {
    final key = Object();
    authors.add(key);
    return key;
  }

  @override
  Future<void> writeBuffer(Object key, int offset, Uint8List data) async {}
  @override
  Future<void> release(Object key) async {
    authors.remove(key);
  }

  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async {
    final key = Object();
    shaders.add(key);
    return ShaderBuild(
      key: key,
      entryPoints: const [
        ShaderEntryPoint(name: 'vertex', stage: ShaderStage.vertex),
        ShaderEntryPoint(name: 'grade', stage: ShaderStage.fragment),
        ShaderEntryPoint(name: 'vignette', stage: ShaderStage.fragment),
      ],
    );
  }

  @override
  Future<void> releaseShader(Object key) async {
    shaders.remove(key);
  }

  @override
  Future<Object> compileGraph(GraphDeviceDescription description) async {
    await gate?.future;
    if (reject) throw GraphException(GraphErrorCode.pipelineFailed, 'fixture');
    final key = Object();
    graphs.add(key);
    return key;
  }

  @override
  Future<void> releaseGraph(Object key) async {
    graphs.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Backend extends UnsupportedBackend implements GraphBackend {
  final device = Device();
  Completer<void>? frameGate, frameEntered;
  late GraphCompiler compiler;
  CompiledGraph? submitted;
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'effects fixture',
    features: EffectsPlugin.features,
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 4096),
  );
  @override
  ResourceScope createResourceScope({String label = ''}) =>
      ResourceScope(device);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      ShaderCompiler(device);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      compiler = GraphCompiler(device);
  @override
  Future<FrameOutput> render(FrameSubmission frame) async {
    submitted = frame.graph;
    if (!(frameEntered?.isCompleted ?? true)) frameEntered!.complete();
    await frameGate?.future;
    return ReadbackOutput(
      image: ImageData(pixels: Uint8List(4), size: PhysicalSize(1, 1)),
      stats: FrameStats(
        frameId: frames++,
        physicalSize: frame.size,
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
}

void main() {
  test(
    'closing effects while a submitted frame finishes preserves its result',
    () async {
      final backend = Backend(), plugin = EffectsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      await engine.renderFrame(elapsed: Duration.zero, width: 17, height: 13);
      backend.frameGate = Completer<void>();
      backend.frameEntered = Completer<void>();
      final pending = engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
      );
      await backend.frameEntered!.future;
      final closing = engine.dispose();
      backend.frameGate!.complete();
      try {
        await pending;
      } finally {
        await closing;
      }
      expect(backend.device.graphs, isEmpty);
      expect(backend.device.authors, isEmpty);
    },
  );
  test(
    'failed resize releases candidates and preserves the previous graph',
    () async {
      final backend = Backend(), plugin = EffectsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      Future<FrameOutput> draw(int w) =>
          engine.renderFrame(elapsed: Duration.zero, width: w, height: 13);
      try {
        await draw(17);
        final previous = backend.submitted!;
        expect(backend.device.authors.length, 1);
        backend.device.reject = true;
        await expectLater(draw(23), throwsA(isA<GraphException>()));
        expect(backend.device.authors.length, 1);
        expect(previous.isClosed, isFalse);
        expect(plugin.state.size!.width, 17);
        await draw(17);
        expect(backend.submitted, same(previous));
        backend.device.reject = false;
        await draw(23);
        expect(previous.isClosed, isTrue);
        expect(backend.device.graphs.length, 1);
        expect(plugin.state.graphBuilds, 2);
      } finally {
        await engine.dispose();
      }
      expect(backend.device.authors, isEmpty);
      expect(backend.device.graphs, isEmpty);
      expect(backend.device.shaders, isEmpty);
    },
  );
  test(
    'closing during a resize drains the candidate without publishing it',
    () async {
      final backend = Backend(), plugin = EffectsPlugin();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      backend.device.gate = Completer<void>();
      final frame = engine.renderFrame(
        elapsed: Duration.zero,
        width: 17,
        height: 13,
      );
      final rejected = expectLater(frame, throwsStateError);
      while (backend.device.authors.length != 4) {
        await Future<void>.delayed(Duration.zero);
      }
      final closing = engine.dispose();
      backend.device.gate!.complete();
      await rejected;
      await closing;
      expect(backend.submitted, isNull);
      expect(backend.device.authors, isEmpty);
      expect(backend.device.graphs, isEmpty);
      expect(plugin.state.availability, EffectsAvailability.detached);
    },
  );
}
