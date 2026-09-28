import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/instancing_checks.dart';
import 'support/instance_color_checks.dart';

void main() {
  for (final entry in {
    'uploads and 10000 instances': verifyInstancing,
    'material pixels': verifyInstanceMaterials,
    'per-instance color pixels': verifyInstanceColors,
    'shadow invalidation': verifyInstanceShadows,
    'transparent ordering': verifyInstanceBlendOrder,
  }.entries) {
    test('native instancing ${entry.key}', () async {
      final backend = await NativeBackend.create();
      try {
        await entry.value(backend);
      } finally {
        await backend.close();
      }
    }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
  }
  test(
    'shared views retain independent instance versions until close',
    () async {
      final a = await NativeBackend.create(), b = a.createView();
      try {
        final mesh = InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 2);
        mesh.setTransforms(0, [
          Mat4.compose(const Vec3(-.7, 0, 0), Quat.identity, Vec3.one),
          Mat4.compose(const Vec3(.7, 0, 0), Quat.identity, Vec3.one),
        ]);
        final scene = Scene()..add(mesh);
        FrameSubmission capture() => FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(position: const Vec3(0, 0, 4)),
          size: PhysicalSize(31, 31),
        );
        final frozen = capture();
        final original = await a.render(frozen) as ReadbackOutput;
        await b.render(frozen);
        mesh.setColor(1, const Color3(1, 0, 0));
        final changed = await a.render(capture()) as ReadbackOutput;
        expect(changed.stats.uploadedBytes, 128);
        final old = await b.render(frozen) as ReadbackOutput;
        expect(old.stats.uploadedBytes, 0);
        expect(old.image.pixels, orderedEquals(original.image.pixels));
        expect(changed.image.pixels, isNot(orderedEquals(old.image.pixels)));
        await a.close();
        expect(
          (await b.render(frozen) as ReadbackOutput).image.pixels,
          orderedEquals(old.image.pixels),
        );
      } finally {
        await a.close();
        await b.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
