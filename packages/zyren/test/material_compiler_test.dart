import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'render_graph_test.dart' as fixtures;

class Device extends fixtures.Device implements MaterialDevice {
  final materials = <Object, int>{};
  Completer<void>? materialGate;
  bool failMaterial = false;
  @override
  Future<Object> compileMaterial(GraphDeviceDescription description) async {
    await materialGate?.future;
    if (failMaterial) {
      throw GraphException(GraphErrorCode.pipelineFailed, 'Bad shader layout.');
    }
    final key = Object();
    materials[key] = 1;
    return key;
  }

  @override
  Future<void> releaseMaterial(Object key) async {
    if (materials[key] == 1) {
      materials.remove(key);
    } else {
      materials[key] = materials[key]! - 1;
    }
  }

  @override
  Future<void> retainMaterial(Object key) async {
    materials[key] = materials[key]! + 1;
  }

  @override
  Uint8List encodeMaterialKey(Object key) => Uint8List(32)..[0] = 7;
}

void main() {
  test(
    'retained material outlives its first compiler on the shared device',
    () async {
      final device = Device();
      final programs = ShaderCompiler(device);
      final owner = MaterialCompiler(device),
          borrower = MaterialCompiler(device);
      final shader = await owner.compile(
        MeshShaderDescriptor(
          program: await programs.compile(ShaderSource.wgsl('valid')),
        ),
      );
      final retained = await borrower.retain(shader);
      await owner.close();
      expect(shader.isClosed, isTrue);
      expect(retained.isClosed, isFalse);
      expect(device.materials.values.single, 1);
      expect(retained.encodeForDevice(device).first, 7);
      await borrower.close();
      expect(device.materials, isEmpty);
      await programs.close();
    },
  );
  test(
    'material compilation checks bindings and preserves earlier candidates',
    () async {
      final device = Device();
      final shaders = ShaderCompiler(device);
      final compiler = MaterialCompiler(device);
      final scope = ResourceScope(device);
      final program = await shaders.compile(ShaderSource.wgsl('valid'));
      final texture = await scope.createTexture(
        TextureDescriptor(
          width: 2,
          height: 2,
          format: TextureFormat.rgba8Unorm,
          usage: {TextureUsage.sampled, TextureUsage.storage},
        ),
      );
      final descriptor = MeshShaderDescriptor(
        program: program,
        bindings: ShaderBindings([
          TextureBinding.sampled(0, texture, group: 1),
        ]),
      );
      final shader = await compiler.compile(descriptor);
      expect(shader.encodeForDevice(device).first, 7);
      for (final binding in [
        TextureBinding.sampled(0, texture),
        TextureBinding.storage(0, texture, group: 1),
      ]) {
        await expectLater(
          compiler.compile(
            MeshShaderDescriptor(
              program: program,
              bindings: ShaderBindings([binding]),
            ),
          ),
          throwsA(isA<GraphException>()),
        );
      }
      device.failMaterial = true;
      await expectLater(
        compiler.compile(descriptor),
        throwsA(isA<GraphException>()),
      );
      expect(device.materials, hasLength(1));
      expect(shader.isClosed, isFalse);
      expect(
        () => shader.encodeForDevice(Device()),
        throwsA(isA<GraphException>()),
      );
      await compiler.close();
      expect(device.materials, isEmpty);
      expect(() => shader.encodeForDevice(device), throwsStateError);
      await scope.close();
      await shaders.close();
    },
  );

  test(
    'material close drains compilation before retiring its candidate',
    () async {
      final device = Device()..materialGate = Completer<void>();
      final shaders = ShaderCompiler(device);
      final program = await shaders.compile(ShaderSource.wgsl('valid'));
      final compiler = MaterialCompiler(device);
      final pending = compiler.compile(MeshShaderDescriptor(program: program));
      final closing = compiler.close();
      device.materialGate!.complete();
      await expectLater(pending, throwsStateError);
      await closing;
      expect(device.materials, isEmpty);
      await shaders.close();
    },
  );

  test(
    'custom material frames require the owning device and capture token identity',
    () async {
      final device = Device();
      final shaders = ShaderCompiler(device);
      final compiler = MaterialCompiler(device);
      final shader = await compiler.compile(
        MeshShaderDescriptor(
          program: await shaders.compile(ShaderSource.wgsl('valid')),
        ),
      );
      final material = ShaderMaterial(
        shader,
        side: MaterialSide.front,
        opacity: .5,
        alphaMode: MaterialAlphaMode.blend,
      );
      final copy = material.copyWith(color: const Color3(1, 0, 0));
      expect(copy.shader, same(shader));
      expect(copy.side, MaterialSide.front);
      expect(copy.opacity, .5);
      expect(copy.writesDepth, isFalse);
      final scene = Scene()..add(Mesh(PlaneGeometry(), material));
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(32, 32),
      );
      expect(
        () => ScenePacketEncoder(viewId: 1).encode(frame),
        throwsUnsupportedError,
      );
      final encoder = ScenePacketEncoder(viewId: 1, materialDevice: device);
      final packet = encoder.encode(frame);
      expect(
        ByteData.sublistView(packet.bytes).getUint32(4, Endian.little),
        36,
      );
      expect(frame.toNativePacket, throwsUnsupportedError);
      expect(
        () => scene.snapshot(PerspectiveCamera(), 1),
        throwsUnsupportedError,
      );
      await compiler.close();
      await shaders.close();
    },
  );
}
