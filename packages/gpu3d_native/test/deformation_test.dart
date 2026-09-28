import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/deformation_checks.dart';

void main() {
  for (final entry in {
    'materials': verifyDeformationMaterials,
    'shadows': verifyDeformationShadows,
    'transparent depth': verifyDeformationBlendOrder,
  }.entries) {
    test('native deformation ${entry.key}', () async {
      final backend = await NativeBackend.create();
      try {
        await entry.value(backend);
      } finally {
        await backend.close();
      }
    }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
  }
  test(
    'native morph pixels match an explicit CPU reference and preserve view poses',
    () async {
      final backend = await NativeBackend.create(),
          other = backend.createView();
      try {
        final geometry = BufferGeometry(
          positions: [-.7, -.5, 0, .3, -.5, 0, -.2, .5, 0],
          normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: [0, 1, 2],
          morphTargets: [
            MorphTarget(positions: [.4, 0, 0, .4, 0, 0, .8, .2, 0]),
          ],
        );
        final mesh = Mesh(geometry, UnlitMaterial(color: Color3(1, .3, .1)));
        final scene = Scene()..add(mesh);
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        FrameSubmission capture(Scene scene) => FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(97, 97),
        );
        final frozen = capture(scene);
        final original = await backend.render(frozen) as ReadbackOutput;
        await other.render(frozen);
        mesh.setMorphWeight(0, .8);
        final changed = await backend.render(capture(scene)) as ReadbackOutput;
        expect(
          changed.stats.uploadedBytes,
          mesh.captureDeformation()!.gpuByteLength,
        );
        expect(
          changed.image.pixels,
          isNot(orderedEquals(original.image.pixels)),
        );
        final reference = Mesh(
          BufferGeometry(
            positions: [
              for (var i = 0; i < 3; i++) ...mesh.vertexPosition(i).storage,
            ],
            normals: geometry.normals,
            indices: geometry.indices,
          ),
          mesh.material,
        );
        final expected =
            await backend.render(capture(Scene()..add(reference)))
                as ReadbackOutput;
        expect(changed.image.pixels, orderedEquals(expected.image.pixels));
        final retained = await other.render(frozen) as ReadbackOutput;
        expect(retained.stats.uploadedBytes, 0);
        expect(retained.image.pixels, orderedEquals(original.image.pixels));
      } finally {
        await backend.close();
        await other.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
