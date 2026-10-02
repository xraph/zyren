import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  test('offscreen color casters still shadow visible receivers', () async {
    final backend = await NativeBackend.create();
    final scene = Scene()
      ..background = const Color3(0, 0, 0)
      ..ambient = 0;
    scene.add(
      Mesh(
        PlaneGeometry(width: 5, height: 5),
        StandardMaterial(baseColor: const Color3(1, 1, 1), roughness: 1),
      )..receiveShadow = true,
    );
    final caster = scene.add(
      Mesh(BoxGeometry(), UnlitMaterial())..position = const Vec3(3, 0, 3),
    );
    scene.add(
      DirectionalLight(
        shadow: DirectionalShadow(
          cascades: 1,
          distance: 10,
          normalBias: 0,
          filterRadius: 0,
        ),
      )..lookAt(const Vec3(-1, 0, -1)),
    );
    final camera = OrthographicCamera(verticalSize: 4, near: .1, far: 10);
    Future<ReadbackOutput> render() async =>
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(64, 64),
              ),
            )
            as ReadbackOutput;
    int center(ReadbackOutput output) =>
        output.image.pixels[(32 * 64 + 32) * 4];
    try {
      final lit = await render();
      expect(lit.stats.drawCalls, 1);
      expect(center(lit), greaterThan(100));
      caster.castShadow = true;
      final shadowed = await render();
      expect(shadowed.stats.drawCalls, 1);
      expect(center(shadowed), lessThan(10));
      caster.castShadow = false;
      expect(center(await render()), closeTo(center(lit), 1));
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
  test(
    'native color visibility changes pixels without discarding geometry',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(0, 0, 0);
      final mesh = scene.add(
        Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(1, 0, 0))),
      );
      final camera = OrthographicCamera(verticalSize: 4);
      Future<ReadbackOutput> render() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: PhysicalSize(32, 32),
                ),
              )
              as ReadbackOutput;
      List<int> center(ReadbackOutput output) =>
          output.image.pixels.sublist((16 * 32 + 16) * 4, (16 * 32 + 17) * 4);
      try {
        expect(center(await render()), [255, 0, 0, 255]);
        final resident = (await backend.resourceStats()).residentBytes;
        mesh.cullingBounds = Bounds3(
          const Vec3(20, 0, 0),
          const Vec3(21, 1, 1),
        );
        final culled = await render();
        expect(center(culled), [0, 0, 0, 255]);
        expect(culled.stats.drawCalls, 0);
        expect(culled.stats.uploadedBytes, 0);
        expect((await backend.resourceStats()).residentBytes, resident);
        mesh.cullingBounds = null;
        final restored = await render();
        expect(center(restored), [255, 0, 0, 255]);
        expect(restored.stats.uploadedBytes, 0);
        scene.remove(mesh);
        await render();
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
