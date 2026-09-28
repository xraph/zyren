import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import '../../../gpu3d_gltf/test/support/deformation_fixture.dart';

final class _Source implements ByteSourceResolver {
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: deformationModel());
}

Future<void> verifyGltfDeformation(NativeGpuBackend backend) async {
  final scope = AssetScope(services: AssetServices(resolver: _Source()));
  try {
    final model = await scope.load(Gltf.asset('deformation.glb')).result;
    final left = model.instantiate()..position = const Vec3(-1.2, 0, 0);
    final right = model.instantiate()..position = const Vec3(1.2, 0, 0);
    Mesh mesh(ModelInstance instance) =>
        instance.nodes[1]!.children.whereType<Mesh>().single;
    mesh(left).material = UnlitMaterial(
      color: const Color3(1, .2, 0),
      side: MaterialSide.doubleSided,
    );
    mesh(right).material = UnlitMaterial(
      color: const Color3(0, .2, 1),
      side: MaterialSide.doubleSided,
    );
    final scene = Scene()
      ..background = const Color3(0, 0, 0)
      ..add(left)
      ..add(right);
    final camera = PerspectiveCamera(position: const Vec3(0, 0, 9));
    FrameSubmission capture(Scene scene) => FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(101, 101),
    );
    final startFrame = capture(scene);
    final start = await backend.render(startFrame) as ReadbackOutput;
    final action = left.mixer.play(left.animations.single)..pause();
    action.seek(const Duration(milliseconds: 500));
    left.nodes[3]!.position = const Vec3(.5, 2, 0);
    scope.release(model);
    final changed = await backend.render(capture(scene)) as ReadbackOutput;
    expect(changed.stats.uploadedBytes, 400);
    expect(changed.image.pixels, isNot(orderedEquals(start.image.pixels)));
    expect(mesh(right).morphWeights, [.3, .4]);
    final expectedScene = Scene()..background = scene.background;
    for (final instance in [left, right]) {
      final original = mesh(instance);
      final world = original.worldMatrix.storage;
      final positions = <double>[];
      for (var i = 0; i < original.geometry.vertexCount; i++) {
        final p = original.vertexPosition(i);
        positions.addAll([
          world[0] * p.x + world[4] * p.y + world[8] * p.z + world[12],
          world[1] * p.x + world[5] * p.y + world[9] * p.z + world[13],
          world[2] * p.x + world[6] * p.y + world[10] * p.z + world[14],
        ]);
      }
      expectedScene.add(
        Mesh(
          BufferGeometry(
            positions: positions,
            normals: original.geometry.normals,
            indices: original.geometry.indices,
          ),
          original.material,
        ),
      );
    }
    final expected =
        await backend.render(capture(expectedScene)) as ReadbackOutput;
    expect(changed.image.pixels, orderedEquals(expected.image.pixels));
    final restored = await backend.render(startFrame) as ReadbackOutput;
    expect(restored.image.pixels, orderedEquals(start.image.pixels));
  } finally {
    await scope.close();
  }
}
