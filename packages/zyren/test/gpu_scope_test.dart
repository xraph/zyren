import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'support/fakes.dart';

class Device implements MaterialDevice {
  final live = <Object>{};
  Completer<void>? gate;
  bool failRelease = false;
  @override
  Future<Object> createTexture(TextureDescriptor descriptor) async {
    await gate?.future;
    final key = Object();
    live.add(key);
    return key;
  }

  @override
  Future<void> release(Object key) async {
    live.remove(key);
    if (failRelease) throw StateError('release failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Backend implements MaterialBackend {
  final device = Device();
  @override
  ResourceScope createResourceScope({String label = ''}) =>
      ResourceScope(device, label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      ShaderCompiler(device, label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      GraphCompiler(device, label: label);
  @override
  MaterialCompiler createMaterialCompiler({String label = ''}) =>
      MaterialCompiler(device, label: label);
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'test',
    features: RenderFeature.values.toSet(),
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 1024),
  );
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final descriptor = TextureDescriptor(
    width: 1,
    height: 1,
    usage: {TextureUsage.sampled},
  );
  test(
    'child GPU scopes retire replacements and close pending allocations',
    () async {
      final backend = Backend();
      final root = GpuScope.fromBackend(backend);
      for (var i = 0; i < 50; i++) {
        final child = root.createChild();
        await child.resources.createTexture(descriptor);
        expect(root.childCount, 1);
        await child.close();
        expect(root.childCount, 0);
        expect(backend.device.live, isEmpty);
      }
      final child = root.createChild();
      backend.device.gate = Completer<void>();
      final allocating = child.resources.createTexture(descriptor);
      final check = expectLater(allocating, throwsStateError);
      final closed = root.close();
      expect(child.isClosed, isTrue);
      expect(() => root.createChild(), throwsStateError);
      backend.device.gate!.complete();
      await check;
      await closed;
      expect(backend.device.live, isEmpty);
      await root.close();
    },
  );
  test(
    'plugin owns child scopes on failed attach and cleanup failure',
    () async {
      final backend = Backend();
      late GpuScope child;
      final result = SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [
          TestPlugin(
            'candidate',
            [],
            onAttach: (context) async {
              child = context.createGpuScope();
              await child.resources.createTexture(descriptor);
              throw StateError('attach failure');
            },
          ),
        ],
      );
      await expectLater(result, throwsStateError);
      expect(child.isClosed, isTrue);
      expect(backend.device.live, isEmpty);
      final root = GpuScope.fromBackend(backend);
      final a = root.createChild(), b = root.createChild();
      await a.resources.createTexture(descriptor);
      await b.resources.createTexture(descriptor);
      backend.device.failRelease = true;
      await expectLater(root.close(), throwsA(isA<ScopeCleanupException>()));
      expect(a.isClosed && b.isClosed, isTrue);
      expect(backend.device.live, isEmpty);
    },
  );
}
