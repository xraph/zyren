import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  for (final strategy in DepthStrategy.values) {
    test(
      '$strategy native sections cut materials, instances and expanded primitives without geometry uploads',
      () async {
        final backend = await NativeBackend.create();
        final camera = OrthographicCamera(
          depthStrategy: strategy,
          left: -1,
          right: 1,
          top: 1,
          bottom: -1,
          near: .1,
          far: 10,
          position: const Vec3(0, 0, 3),
        );
        final scene = Scene()..background = const Color3(0, 0, 0);
        final group = scene.add(Group());
        final sun = scene.add(DirectionalLight());
        final plane = ClippingPlane(normal: const Vec3(1, 0, 0));
        Future<ReadbackOutput> render() async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(33, 33),
                  ),
                )
                as ReadbackOutput;
        int red(ReadbackOutput output, int x) =>
            output.image.pixels[(16 * 33 + x) * 4];
        final map = TextureMap(
          image: TextureImage.rgba(
            width: 1,
            height: 1,
            pixels: Uint8List.fromList([255, 0, 0, 255]),
          ),
        );
        try {
          for (final material in <MeshMaterial>[
            UnlitMaterial(color: const Color3(1, 0, 0)),
            DiffuseMaterial(colorMap: map),
            StandardMaterial(colorMap: map),
          ]) {
            for (final instanced in [false, true]) {
              final geometry = PlaneGeometry(width: 2, height: 2);
              final mesh = group.add(
                instanced
                    ? InstancedMesh(geometry, material, count: 1)
                    : Mesh(geometry, material),
              );
              scene.clippingPlanes = [];
              final whole = await render();
              expect(red(whole, 8), greaterThan(20));
              scene.clippingPlanes = [plane];
              final cut = await render();
              expect(red(cut, 8), 0);
              expect(red(cut, 24), red(whole, 24));
              expect(cut.stats.uploadedBytes, 0);
              scene.clippingPlanes = [plane.flipped];
              expect(red(await render(), 24), 0);
              group.clippingEnabled = false;
              expect((await render()).image.pixels, whole.image.pixels);
              group.clippingEnabled = true;
              scene.clippingPlanes = [];
              expect((await render()).image.pixels, whole.image.pixels);
              group.remove(mesh);
            }
          }
          final primitives = <Mesh>[
            Line(
              LineGeometry(points: [const Vec3(-1, 0, 0), const Vec3(1, 0, 0)]),
              LineMaterial(width: 9, color: const Color3(1, 0, 0)),
            ),
            Points(
              PointGeometry(points: [Vec3.zero]),
              PointsMaterial(
                size: 30,
                shape: PointShape.square,
                color: const Color3(1, 0, 0),
              ),
            ),
          ];
          for (final mesh in primitives) {
            group.add(mesh);
            scene.clippingPlanes = [plane];
            final cut = await render();
            expect(red(cut, 8), 0);
            expect(red(cut, 24), 255);
            group.remove(mesh);
          }
          group.add(
            Mesh(
              PlaneGeometry(width: 2, height: 2),
              UnlitMaterial(color: const Color3(1, 0, 0)),
            ),
          );
          group.position = const Vec3(1000000000, 0, 0);
          camera.position = const Vec3(1000000000, 0, 3);
          camera.target = const Vec3(1000000000, 0, 0);
          scene.clippingPlanes = [
            ClippingPlane(normal: const Vec3(1, 0, 0), offset: 1000000000.25),
          ];
          final distant = await render();
          expect(red(distant, 16), 0);
          expect(red(distant, 24), 255);
          scene.remove(sun);
          expect(red(await render(), 24), 255);
          expect(
            (await backend.graphStats()).targetBytes,
            0,
            reason: 'Section planes alone must not allocate HDR targets.',
          );
        } finally {
          await backend.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );

    test(
      '$strategy clipped casters release shadows and invalidate cached atlases',
      () async {
        final backend = await NativeBackend.create();
        final scene = Scene()
          ..background = const Color3(0, 0, 0)
          ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
        scene.add(Mesh(PlaneGeometry(width: 4, height: 4), StandardMaterial()));
        final blocker = scene.add(
          InstancedMesh(
              PlaneGeometry(width: .4, height: .4),
              UnlitMaterial(),
              count: 1,
            )
            ..position = const Vec3(-.5, 0, 1)
            ..castShadow = true,
        );
        scene.add(
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
        final camera = OrthographicCamera(
          depthStrategy: strategy,
          left: -1,
          right: 1,
          top: 1,
          bottom: -1,
          near: .1,
          far: 10,
          position: const Vec3(0, 0, 3),
        );
        Future<int> red() async {
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(33, 33),
                    ),
                  )
                  as ReadbackOutput;
          return output.image.pixels[(16 * 33 + 16) * 4];
        }

        try {
          expect(await red(), lessThan(5));
          final passes = (await backend.graphStats()).shadowPasses;
          scene.clippingPlanes = [
            ClippingPlane(normal: const Vec3(0, 0, -1), offset: -.5),
          ];
          expect(await red(), greaterThan(80));
          expect((await backend.graphStats()).shadowPasses, passes + 2);
          await red();
          expect((await backend.graphStats()).shadowPasses, passes + 2);
          blocker.clippingEnabled = false;
          expect(await red(), lessThan(5));
          blocker.clippingEnabled = true;
          scene.clippingPlanes = [];
          expect(await red(), lessThan(5));
        } finally {
          await backend.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }
}
