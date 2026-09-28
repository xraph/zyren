import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'deformation_checks.dart' show skinBox;

/// Compare CPU selections with actual native rasterized object colors.
Future<void> verifyPickingPixels(NativeGpuBackend backend) async {
  final scene = Scene()..background = const Color3(0, 0, 0);
  final geometry = skinBox();
  final group = scene.add(Group()..position = const Vec3(-.8, 0, 0));
  final root = group.add(Bone()), tip = root.add(Bone());
  final skin = group.add(
    SkinnedMesh(
      geometry,
      UnlitMaterial(color: const Color3(1, 0, 0), side: MaterialSide.front),
      skin: Skin.fromBindPose(
        joints: [root, tip],
        meshBindMatrix: group.worldMatrix,
      ),
    ),
  );
  tip.rotateZ(.4);
  skin.setMorphWeight(0, .7);
  final instances = scene.add(
    InstancedMesh(
      geometry,
      UnlitMaterial(color: const Color3(1, 1, 1), side: MaterialSide.front),
      count: 2,
    ),
  );
  instances.setTransforms(0, [
    Mat4.compose(
      const Vec3(.7, -.4, .2),
      Quat.axisAngle(const Vec3(0, 1, 0), .3),
      const Vec3(-.6, .7, 1.2),
    ),
    Mat4.compose(const Vec3(.8, .55, 0), Quat.identity, const Vec3(.8, .5, .7)),
  ]);
  instances.setColors(0, [const Color3(0, 1, 0), const Color3(0, 0, 1)]);
  instances.setMorphWeight(0, .4);
  // An overlapping object on another layer must neither draw nor receive picks.
  scene.add(
    Mesh(BoxGeometry(width: 4, height: 4), UnlitMaterial())
      ..position = const Vec3(0, 0, 1)
      ..layers = LayerMask.only(3),
  );
  const size = 83;
  for (final Camera camera in [
    PerspectiveCamera(position: const Vec3(0, 0, 4)),
    OrthographicCamera(position: const Vec3(0, 0, 4), verticalSize: 3.8),
  ]) {
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(size, size),
              ),
            )
            as ReadbackOutput;
    final pixels = output.image.pixels;
    final counts = [0, 0, 0, 0];
    for (var y = 2; y < size; y += 3) {
      for (var x = 2; x < size; x += 3) {
        final hit = Raycaster()
            .captureFromCamera(
              scene,
              camera,
              ViewportPoint(x + .5, y + .5),
              logicalWidth: size.toDouble(),
              logicalHeight: size.toDouble(),
            )
            .intersectFirst();
        if (hit != null &&
            [
              hit.barycentric.x,
              hit.barycentric.y,
              hit.barycentric.z,
            ].any((v) => v < 1e-5)) {
          continue;
        }
        final channel = hit == null
            ? 3
            : identical(hit.object, skin)
            ? 0
            : hit.instanceIndex! + 1;
        counts[channel]++;
        for (var c = 0; c < 3; c++) {
          expect(
            pixels[(y * size + x) * 4 + c],
            channel == c ? 255 : 0,
            reason:
                '${camera.runtimeType} ($x,$y), channel $c, picked $channel',
          );
        }
      }
    }
    expect(
      counts,
      everyElement(greaterThan(10)),
      reason:
          'Both projections must sample all three objects and the background.',
    );
  }
}
