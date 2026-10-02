import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native instances match ordinary meshes, sort transparency and retain captured views',
    () async {
      final backend = await NativeBackend.create(),
          other = backend.createView();
      final camera = OrthographicCamera(
        left: -2,
        right: 2,
        top: 1,
        bottom: -1,
        near: .1,
        far: 10,
        position: const Vec3(0, 0, 4),
      );
      final scene = Scene()..background = const Color3(0, 0, 0);
      final material = StandardMaterial(
        baseColor: const Color3(.3, .5, .2),
        side: MaterialSide.front,
      );
      final geometry = PlaneGeometry(width: 1.5, height: 1.5);
      final instances = scene.add(InstancedMesh(geometry, material, count: 2));
      instances.setTransform(
        0,
        Mat4.compose(const Vec3(-1, 0, 0), Quat.identity, Vec3.one),
      );
      instances.setTransform(
        1,
        Mat4.compose(const Vec3(1, 0, 0), Quat.identity, const Vec3(-1, .7, 1)),
      );
      scene.add(DirectionalLight());
      final manual = Scene()..background = scene.background;
      manual.add(DirectionalLight());
      final a = manual.add(
        Mesh(geometry, material)..position = const Vec3(-1, 0, 0),
      );
      final b = manual.add(
        Mesh(geometry, material)
          ..position = const Vec3(1, 0, 0)
          ..scale = const Vec3(-1, .7, 1),
      );
      FrameSubmission capture(Scene value) => FrameSubmission.capture(
        scene: value,
        camera: camera,
        size: PhysicalSize(64, 32),
      );
      Future<ReadbackOutput> render(Scene value) async =>
          await backend.render(capture(value)) as ReadbackOutput;
      try {
        final initial = capture(scene);
        final expected = (await render(manual)).image.pixels;
        final output = await render(scene);
        expect(output.image.pixels, expected);
        expect(output.stats.drawCalls, 1);
        expect((await backend.graphStats()).instanceBytes, 256);
        final bytes = (await backend.graphStats()).instanceUploadedBytes;
        await render(scene);
        expect((await backend.graphStats()).instanceUploadedBytes, bytes);
        final retained = await other.render(initial) as ReadbackOutput;
        expect(retained.image.pixels, expected);
        instances.setTransform(
          1,
          Mat4.compose(
            const Vec3(.2, 0, 0),
            Quat.identity,
            const Vec3(-1, .7, 1),
          ),
        );
        b.position = const Vec3(.2, 0, 0);
        final previous = (await backend.graphStats()).instanceUploadedBytes;
        final changed = await render(scene);
        expect(
          (await backend.graphStats()).instanceUploadedBytes - previous,
          128,
        );
        expect(changed.image.pixels, (await render(manual)).image.pixels);
        expect(
          (await other.render(initial) as ReadbackOutput).image.pixels,
          expected,
        );

        final blend = UnlitMaterial(
          color: const Color3(1, 0, 0),
          opacity: .4,
          alphaMode: MaterialAlphaMode.blend,
        );
        instances.material = blend;
        a.material = b.material = blend;
        a.position = const Vec3(0, 0, -1);
        b.position = const Vec3(0, 0, 1);
        b.scale = Vec3.one;
        instances.setTransform(0, a.localMatrix);
        instances.setTransform(1, b.localMatrix);
        final green = UnlitMaterial(
          color: const Color3(0, 1, 0),
          opacity: .5,
          alphaMode: MaterialAlphaMode.blend,
        );
        scene.add(Mesh(geometry, green));
        manual.add(Mesh(geometry, green));
        expect(capture(scene).scene.drawCalls, 3);
        expect(
          (await render(scene)).image.pixels,
          (await render(manual)).image.pixels,
        );
        await other.close();
        await render(Scene());
        expect((await backend.graphStats()).instanceBytes, 0);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await other.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'instanced tangent frames and masked shadow casters match ordinary geometry',
    () async {
      final backend = await NativeBackend.create();
      final plane = PlaneGeometry(width: .5, height: .7);
      final geometry = BufferGeometry.fromAttributes(
        attributes: {
          ...plane.attributes,
          VertexSemantic.tangent: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 4; i++) ...[1.0, 0.0, 0.0, -1.0],
            ]),
            format: VertexFormat.float32x4,
          ),
        },
        indices: plane.indices,
      );
      TextureMap map(List<int> pixels) => TextureMap(
        image: TextureImage.rgba(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList(pixels),
          format: TextureFormat.rgba8Unorm,
        ),
      );
      final material = StandardMaterial(
        normalMap: map([128, 180, 240, 255]),
        colorMap: map([120, 240, 190, 255]),
        alphaMode: MaterialAlphaMode.mask,
        side: MaterialSide.front,
      );
      final scene = Scene(), manual = Scene();
      final instances = scene.add(InstancedMesh(geometry, material, count: 2))
        ..castShadow = true;
      final ordinary = <Mesh>[];
      for (var i = 0; i < 2; i++) {
        final mesh = manual.add(
          Mesh(geometry, material)
            ..position = Vec3(-.5 + i, 0, 1)
            ..scale = Vec3(i == 0 ? 1 : -1, 1, 1)
            ..castShadow = true,
        );
        instances.setTransform(i, mesh.localMatrix);
        ordinary.add(mesh);
      }
      for (final value in [scene, manual]) {
        value.add(Mesh(PlaneGeometry(width: 4, height: 4), StandardMaterial()));
        value.add(
          DirectionalLight(
            direction: const Vec3(.5, 0, -1),
            shadow: ShadowSettings(
              cascades: 2,
              resolution: 256,
              maxDistance: 10,
              normalBias: 0,
            ),
          ),
        );
      }
      final camera = OrthographicCamera(
        left: -2,
        right: 2,
        top: 1,
        bottom: -1,
        near: .1,
        far: 10,
        position: const Vec3(0, 0, 4),
      );
      Future<Uint8List> render(Scene value) async =>
          (await backend.render(
                    FrameSubmission.capture(
                      scene: value,
                      camera: camera,
                      size: PhysicalSize(65, 33),
                    ),
                  )
                  as ReadbackOutput)
              .image
              .pixels;
      try {
        final expected = await render(manual);
        expect(await render(scene), expected);
        final empty = material.copyWith(colorMap: map([255, 255, 255, 0]));
        instances.material = empty;
        for (final mesh in ordinary) {
          mesh.material = empty;
        }
        final removed = await render(scene);
        expect(removed, isNot(expected));
        expect(removed, await render(manual));
        await render(Scene());
        expect((await backend.graphStats()).instanceBytes, 0);
        expect((await backend.graphStats()).shadowBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test('ten thousand instances share bounded buffers and one draw', () async {
    final backend = await NativeBackend.create();
    final scene = Scene()..background = const Color3(0, 0, 0);
    final mesh = scene.add(
      InstancedMesh(PlaneGeometry(), UnlitMaterial(), count: 10000),
    );
    for (var i = 0; i < mesh.count; i++) {
      mesh.setTransform(
        i,
        Mat4.compose(
          Vec3((i % 100 - 49.5) * .025, (i ~/ 100 - 49.5) * .025, 0),
          Quat.identity,
          const Vec3(.015, .015, .015),
        ),
      );
    }
    try {
      final output =
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: PerspectiveCamera(),
                  size: PhysicalSize(8, 8),
                ),
              )
              as ReadbackOutput;
      expect(output.stats.drawCalls, 1);
      final stats = await backend.graphStats();
      expect(stats.instanceBytes, 1280000);
      expect(stats.instanceDrawCalls, 1);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test(
    'shared instance versions do not duplicate buffers across views',
    () async {
      final backend = await NativeBackend.create();
      final views = [backend, for (var i = 0; i < 9; i++) backend.createView()];
      final geometry = PlaneGeometry();
      final material = UnlitMaterial();
      final scene = Scene()
        ..add(
          InstancedMesh(geometry, material, count: 65536)
            ..position = const Vec3(100, 0, 0),
        );
      FrameSubmission capture(Scene value) => FrameSubmission.capture(
        scene: value,
        camera: PerspectiveCamera(),
        size: PhysicalSize(2, 2),
      );
      final large = capture(scene),
          small = capture(
            Scene()..add(InstancedMesh(geometry, material, count: 1)),
          );
      try {
        for (var i = 0; i < 9; i++) {
          await views[i].render(large);
        }
        final previous = await views[9].render(small) as ReadbackOutput;
        final bytes = (await backend.graphStats()).instanceBytes;
        await views[9].render(large);
        expect(
          (await backend.graphStats()).instanceBytes,
          lessThanOrEqualTo(bytes),
        );
        expect(
          (await views[9].render(small) as ReadbackOutput).image.pixels,
          previous.image.pixels,
        );
        await views[8].close();
        await views[9].render(large);
        for (var i = 1; i < 10; i++) {
          await views[i].close();
        }
        await backend.render(capture(Scene()));
        expect((await backend.graphStats()).instanceBytes, 0);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        for (final view in views) {
          await view.close();
        }
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
