import 'dart:async';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'shared_graph_test.dart' show SharedBackend, SharedDevice;
import 'support/fakes.dart' show TestPlugin, TestRenderer;

class EnvironmentDevice extends SharedDevice {
  final references = <Object, int>{};
  final programs = <Object>{};
  Completer<void>? executing;
  Object? sourceToReject;
  bool rejectSourceCleanup = false;
  @override
  Future<Object> createTexture(TextureDescriptor descriptor) async {
    final key = await super.createTexture(descriptor);
    references[key] = 1;
    if (descriptor.label == 'HDR environment source') sourceToReject = key;
    return key;
  }

  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) async {
    final key = Object();
    authors.add(key);
    references[key] = 1;
    return key;
  }

  @override
  Future<void> retain(Object key) async =>
      references[key] = references[key]! + 1;
  @override
  Future<void> release(Object key) async {
    final count = references[key]! - 1;
    if (count == 0) {
      references.remove(key);
      authors.remove(key);
    } else {
      references[key] = count;
    }
    if (rejectSourceCleanup && identical(sourceToReject, key) && count == 0) {
      throw StateError('source cleanup failed');
    }
  }

  @override
  Future<void> writeBuffer(Object key, int offset, Uint8List bytes) async {}
  @override
  Future<void> writeTexture(Object key, int mipLevel, Uint8List bytes) async {}
  @override
  Future<void> generateMipmaps(
    Object key,
    MipmapAlphaFilter alphaFilter,
  ) async {}
  @override
  Future<ShaderBuild> compileShader(ShaderSource source) async {
    final build = await super.compileShader(source);
    programs.add(build.key);
    return build;
  }

  @override
  Future<void> releaseShader(Object key) async => programs.remove(key);
  @override
  Future<GraphStats> executeGraph(Object key) {
    if (!(executing?.isCompleted ?? true)) executing!.complete();
    return super.executeGraph(key);
  }
}

class EnvironmentBackend extends SharedBackend {
  final _environmentDevice = EnvironmentDevice();
  @override
  EnvironmentDevice get device => _environmentDevice;
}

const quality = EnvironmentQuality(
  specularWidth: 16,
  diffuseWidth: 16,
  brdfSize: 16,
  samples: 64,
);
HdrImageData image(double value) => HdrImageData(
  pixels: Float32List.fromList([
    value,
    value,
    value,
    1,
    value,
    value,
    value,
    1,
  ]),
  size: PhysicalSize(2, 1),
);
Future<GpuResource<Texture>> source(ResourceScope scope) => scope.createTexture(
  TextureDescriptor(
    width: 16,
    height: 8,
    format: TextureFormat.rgba16Float,
    usage: {TextureUsage.sampled},
  ),
);

void main() {
  test('quality and settings bound integration work before GPU allocation', () {
    for (final invalid in [
      const EnvironmentQuality(specularWidth: 0),
      const EnvironmentQuality(specularWidth: 17),
      const EnvironmentQuality(diffuseWidth: 512),
      const EnvironmentQuality(brdfSize: 1024),
      const EnvironmentQuality(samples: 63),
      const EnvironmentQuality(samples: 2049),
      const EnvironmentQuality(
        specularWidth: 1024,
        diffuseWidth: 256,
        brdfSize: 512,
        samples: 2048,
      ),
    ]) {
      expect(invalid.validate, throwsArgumentError);
    }
    expect(quality.specularMipLevels, 2);
    for (final invalid in [-1.0, double.nan, double.infinity, 1000001.0]) {
      expect(
        () => EnvironmentLighting(intensity: invalid),
        throwsArgumentError,
      );
    }
    expect(
      () => EnvironmentLighting(rotation: const Quat(0, 0, 0, 0)),
      throwsArgumentError,
    );
  });

  test(
    'environment claims reject competing providers, late claims and unsupported backends',
    () async {
      final backend = EnvironmentBackend();
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          backendFactory: () async => backend,
          plugins: [
            for (final id in ['a', 'b'])
              TestPlugin(
                id,
                [],
                onAttach: (context) {
                  context.environment;
                },
              ),
          ],
        ),
        throwsStateError,
      );
      expect(backend.closed, isTrue);
      final lateBackend = EnvironmentBackend();
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => lateBackend,
        plugins: [
          TestPlugin(
            'late',
            [],
            onBefore: (context, _) {
              context.environment;
            },
          ),
        ],
      );
      await expectLater(
        engine.renderFrame(elapsed: Duration.zero, width: 8, height: 8),
        throwsStateError,
      );
      await engine.dispose();
      await expectLater(
        SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(),
          rendererFactory: () async => TestRenderer([]),
          plugins: [EnvironmentLighting()],
        ),
        throwsA(isA<SceneException>()),
      );
    },
  );

  test(
    'failed bake or temporary cleanup releases all candidate resources',
    () async {
      for (final cleanupFailure in [false, true]) {
        final device = EnvironmentDevice()
          ..reject = !cleanupFailure
          ..releaseFailure = cleanupFailure
              ? StateError('retirement failed')
              : null;
        final owner = ResourceScope(device);
        final input = await source(owner);
        await expectLater(
          EnvironmentMap.prefilter(input, resources: owner, quality: quality),
          throwsA(
            cleanupFailure
                ? isA<ScopeCleanupException>()
                : isA<GraphException>(),
          ),
        );
        expect(
          device.references.length,
          1,
          reason: 'only caller source remains',
        );
        expect(device.programs, isEmpty);
        expect(device.graphs, isEmpty);
        await owner.close();
        expect(device.references, isEmpty);
      }
    },
  );

  test(
    'closing during GPU preparation drains work and never returns a closed map',
    () async {
      final device = EnvironmentDevice()
        ..executing = Completer<void>()
        ..executionGate = Completer<void>();
      final owner = ResourceScope(device);
      final pending = EnvironmentMap.prefilter(
        await source(owner),
        resources: owner,
        quality: quality,
      );
      final rejected = expectLater(pending, throwsStateError);
      await device.executing!.future;
      var closed = false;
      final closing = owner.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      device.executionGate!.complete();
      await rejected;
      await closing;
      expect(device.references, isEmpty);
      expect(device.programs, isEmpty);
      expect(device.graphs, isEmpty);
    },
  );

  test(
    'source cleanup failure also releases a successfully prepared map',
    () async {
      final device = EnvironmentDevice()..rejectSourceCleanup = true;
      final owner = ResourceScope(device);
      await expectLater(
        EnvironmentMap.fromEquirectangular(
          image(1),
          resources: owner,
          quality: quality,
        ),
        throwsA(isA<ScopeCleanupException>()),
      );
      expect(device.references, isEmpty);
      expect(device.programs, isEmpty);
      expect(device.graphs, isEmpty);
      await owner.close();
    },
  );

  test(
    'retained maps outlive their source and drain accepted frames',
    () async {
      final device = EnvironmentDevice();
      final owner = ResourceScope(device), other = ResourceScope(device);
      final map = await EnvironmentMap.prefilter(
        await source(owner),
        resources: owner,
        quality: quality,
      );
      final retained = await map.retain(other);
      final settings = Environment(
        map: retained,
        intensity: 2,
        rotation: const Quat(0, 0, 0, 2),
      );
      final frame = FrameSubmission.capture(
        scene: Scene(),
        camera: PerspectiveCamera(),
        size: PhysicalSize(8, 8),
        environment: settings,
      );
      expect(frame.withGraph(null).environment, same(settings));
      expect(settings.rotation, Quat.identity);
      expect(frame.toNativePacket, throwsUnsupportedError);
      await owner.close();
      expect(map.isClosed, isTrue);
      expect(retained.isClosed, isFalse);
      expect(device.references.length, 3);
      await expectLater(
        retained.submitFrame(EnvironmentDevice(), (_) async {}),
        throwsArgumentError,
      );
      final gate = Completer<void>();
      final accepted = retained.submitFrame(device, (_) => gate.future);
      final closing = other.close();
      await Future<void>.delayed(Duration.zero);
      expect(device.references.length, 3);
      gate.complete();
      await accepted;
      await closing;
      expect(device.references, isEmpty);
      await expectLater(
        retained.submitFrame(device, (_) async {}),
        throwsStateError,
      );
    },
  );

  test(
    'prepared plugin replacements wait for the previous frame and retain independent view settings',
    () async {
      final backend = EnvironmentBackend(), second = EnvironmentBackend();
      final lighting = EnvironmentLighting(image: image(1), quality: quality);
      final independent = EnvironmentLighting(
        image: image(1),
        quality: quality,
        intensity: 3,
      );
      Future<SceneEngine> create(
        EnvironmentBackend backend,
        EnvironmentLighting plugin,
      ) => SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [plugin],
      );
      final engine = await create(backend, lighting),
          other = await create(second, independent);
      Future<FrameOutput> draw(SceneEngine engine) =>
          engine.renderFrame(elapsed: Duration.zero, width: 8, height: 8);
      try {
        final original = lighting.map!;
        backend.frameEntered = Completer<void>();
        backend.frameGate = Completer<void>();
        final frame = draw(engine);
        await backend.frameEntered!.future;
        await lighting.setImage(image(2));
        lighting.intensity = .5;
        lighting.rotation = Quat.axisAngle(const Vec3(0, 1, 0), 1);
        expect(original.isClosed, isFalse);
        expect(backend.last!.environment!.intensity, 1);
        backend.frameGate!.complete();
        await frame;
        await draw(engine);
        expect(original.isClosed, isTrue);
        expect(backend.last!.environment!.intensity, .5);
        await draw(other);
        expect(second.last!.environment!.intensity, 3);
        expect(second.last!.environment!.rotation, Quat.identity);
        await expectLater(lighting.setImage(image(70000)), throwsArgumentError);
        await lighting.setImage(null);
        await draw(engine);
        expect(backend.last!.environment, isNull);
      } finally {
        await engine.dispose();
        await other.dispose();
      }
      expect(backend.device.references, isEmpty);
      expect(second.device.references, isEmpty);
    },
  );
}
