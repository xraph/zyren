import 'dart:async';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'render_graph_test.dart' show Device;
import 'frame_graph_test.dart' show FrameBackend;

class MeshDevice extends Device implements MeshShaderDevice {
  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) async => Object();
  final materials = <Object>{}, releasedModules = <Object>[];
  MeshShaderDeviceDescription? description;
  Completer<void>? materialGate;
  void Function()? onCompile;
  @override
  Future<Object> compileMeshShader(
    MeshShaderDeviceDescription description,
  ) async {
    this.description = description;
    onCompile?.call();
    await materialGate?.future;
    final key = Object();
    materials.add(key);
    return key;
  }

  @override
  Future<void> releaseMeshShader(Object key) async {
    materials.remove(key);
  }

  @override
  Future<void> releaseShader(Object key) async {
    releasedModules.add(key);
  }
}

void main() {
  test(
    'one frame admits all of its mesh programs before immediate closure',
    () async {
      final device = MeshDevice();
      final owner = ShaderCompiler(device);
      final first = await owner.compileMesh(ShaderSource.wgsl('valid'));
      final second = await owner.compileMesh(ShaderSource.wgsl('valid'));
      final gate = Completer<void>();
      final frame = first.submitFrame(
        device,
        (_) => second.submitFrame(device, (_) => gate.future),
      );
      final closing = owner.close();
      gate.complete();
      try {
        await frame;
        await closing;
        expect(device.materials, isEmpty);
      } finally {
        await owner.close();
      }
    },
  );
  test('mesh materials reject unsupported backends and missing UVs', () async {
    final device = MeshDevice(), backend = FrameBackend();
    final compiler = ShaderCompiler(device);
    final program = await compiler.compileMesh(
      ShaderSource.wgsl('valid'),
      vertexLayout: MeshVertexLayout.positionNormalUv,
    );
    final scene = Scene()..add(Mesh(BoxGeometry(), ShaderMaterial(program)));
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      backendFactory: () async => backend,
    );
    try {
      await expectLater(
        engine.renderFrame(elapsed: Duration.zero, width: 8, height: 8),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.unsupportedFeature,
          ),
        ),
      );
      expect(backend.last, isNull);
      scene.remove(scene.children.single);
      final mesh = scene.add(
        Mesh(
          BufferGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2],
          ),
          ShaderMaterial(program),
        ),
      );
      expect(
        () => FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(8, 8),
        ),
        throwsArgumentError,
      );
      mesh.visible = false;
      expect(
        FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(8, 8),
        ).scene.meshShaders,
        isEmpty,
      );
    } finally {
      await engine.dispose();
      await compiler.close();
    }
  });
  test(
    'mesh compilation validates bindings and hands module ownership to native material',
    () async {
      final device = MeshDevice();
      final compiler = ShaderCompiler(device), scope = ResourceScope(device);
      final buffer = await scope.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      );
      try {
        final program = await compiler.compileMesh(
          ShaderSource.wgsl('valid'),
          bindings: ShaderBindings([
            BufferBinding.uniform(0, buffer, group: 1),
          ]),
        );
        expect(device.materials.length, 1);
        expect(device.releasedModules.length, 1);
        expect(program.vertexLayout, MeshVertexLayout.positionNormal);
        final material = ShaderMaterial(program, side: MaterialSide.front);
        final scene = Scene()..add(Mesh(BoxGeometry(), material));
        final captured = FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(8, 8),
        );
        expect(captured.scene.meshShaders, {0: program});
        scene.children.single.visible = false;
        expect(captured.scene.meshShaders, {0: program});
        expect(() => captured.toNativePacket(), throwsUnsupportedError);
        await scope.close();
        await program.submitFrame(device, (_) async {});
        await expectLater(
          program.submitFrame(MeshDevice(), (_) async {}),
          throwsA(isA<GraphException>()),
        );
        await compiler.close();
        expect(program.isClosed, isTrue);
        expect(device.materials, isEmpty);
      } finally {
        await compiler.close();
        await scope.close();
      }
    },
  );

  test(
    'reserved groups and writable material bindings fail before native publication',
    () async {
      final device = MeshDevice();
      final own = ShaderCompiler(device), scope = ResourceScope(device);
      final uniform = await scope.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.uniform}),
      );
      final storage = await scope.createTexture(
        TextureDescriptor(
          width: 2,
          height: 2,
          format: TextureFormat.rgba8Unorm,
          usage: {TextureUsage.storage},
        ),
      );
      for (final binding in [
        BufferBinding.uniform(0, uniform),
        TextureBinding.storage(0, storage, group: 1),
      ]) {
        await expectLater(
          own.compileMesh(
            ShaderSource.wgsl('valid'),
            bindings: ShaderBindings([binding]),
          ),
          throwsA(isA<GraphException>()),
        );
      }
      expect(device.materials, isEmpty);
      await scope.close();
      await own.close();
    },
  );

  test(
    'closing drains accepted material frames and rejects further submissions',
    () async {
      final device = MeshDevice();
      final compiler = ShaderCompiler(device);
      final program = await compiler.compileMesh(ShaderSource.wgsl('valid'));
      final gate = Completer<void>(), started = Completer<void>();
      final frame = program.submitFrame(device, (_) {
        started.complete();
        return gate.future;
      });
      await started.future;
      final closing = compiler.close();
      expect(program.isClosed, isTrue);
      await expectLater(
        program.submitFrame(device, (_) async {}),
        throwsStateError,
      );
      expect(device.materials.length, 1);
      gate.complete();
      await frame;
      await closing;
      expect(device.materials, isEmpty);
    },
  );

  test('reentrant close while compiling releases the late material', () async {
    final device = MeshDevice()..materialGate = Completer<void>();
    final compiler = ShaderCompiler(device);
    Future<void>? closing;
    device.onCompile = () {
      closing = compiler.close();
    };
    final future = compiler.compileMesh(ShaderSource.wgsl('valid'));
    final rejected = expectLater(future, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    device.materialGate!.complete();
    await rejected;
    await closing;
    expect(device.materials, isEmpty);
    expect(device.releasedModules.length, 1);
  });
}
