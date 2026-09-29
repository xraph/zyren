import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import 'support/deformation_checks.dart';

double linear(int value) {
  final c = value / 255;
  return c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
}

void main() {
  test(
    'native temporal reconstruction converges and rejects disoccluded history',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mesh = scene.add(
          Mesh(PlaneGeometry(width: 1.3, height: 1.8), UnlitMaterial())
            ..rotateZ(.37),
        );
        final camera = OrthographicCamera(
          position: const Vec3(0, 0, 3),
          verticalSize: 3,
        );
        Future<Uint8List> draw(
          int size, {
          bool temporal = false,
          int reset = 0,
        }) async {
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(size, size),
                      colorPipeline: ColorPipeline(
                        toneMapping: ToneMapping.linear,
                      ),
                      temporalAA: temporal ? TemporalAAOptions() : null,
                      temporalReset: reset,
                    ),
                  )
                  as ReadbackOutput;
          return output.image.pixels;
        }

        final reference = await draw(248), baseline = await draw(31);
        late Uint8List resolved;
        for (var i = 0; i < 8; i++) {
          resolved = await draw(31, temporal: true);
        }
        double error(Uint8List image) {
          var error = 0.0;
          for (var y = 0; y < 31; y++) {
            for (var x = 0; x < 31; x++) {
              var expected = 0.0;
              for (var yy = 0; yy < 8; yy++) {
                for (var xx = 0; xx < 8; xx++) {
                  expected +=
                      linear(reference[((y * 8 + yy) * 248 + x * 8 + xx) * 4]) /
                      64;
                }
              }
              error += math.pow(linear(image[(y * 31 + x) * 4]) - expected, 2);
            }
          }
          return error;
        }

        expect(error(resolved), lessThan(error(baseline) * .75));
        mesh.position = const Vec3(1.5, 0, 0);
        final moved = await draw(31, temporal: true);
        expect(moved[(15 * 31 + 12) * 4], 0);
        final reset = await draw(31, temporal: true, reset: 1);
        expect(reset[(15 * 31 + 12) * 4], 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'temporal animated poses, masks and mirrored instances retain current coverage',
    () async {
      final backend = await NativeBackend.create();
      try {
        final camera = OrthographicCamera(
          position: const Vec3(0, 0, 4),
          verticalSize: 3,
        );
        final map = TextureMap(
          image: TextureImage.rgba(
            width: 2,
            height: 1,
            pixels: Uint8List.fromList([255, 255, 255, 255, 255, 255, 255, 0]),
          ),
        );
        for (final instanced in [false, true]) {
          for (final mode in MaterialAlphaMode.values) {
            final material = UnlitMaterial(
              colorMap: map,
              vertexColors: true,
              alphaMode: mode,
              alphaCutoff: .3,
              opacity: mode == MaterialAlphaMode.blend ? .6 : 1,
            );
            final scene = Scene()..background = const Color3(0, 0, 0);
            final root = scene.add(Bone()), tip = root.add(Bone());
            final Mesh mesh = instanced
                ? InstancedMesh(skinBox(), material, count: 2)
                : SkinnedMesh(
                    skinBox(),
                    material,
                    skin: Skin.fromBindPose(joints: [root, tip]),
                  );
            scene.add(mesh);
            if (mesh is InstancedMesh) {
              mesh.setTransforms(0, [
                Mat4.compose(
                  const Vec3(-.5, 0, 0),
                  Quat.identity,
                  const Vec3(-.7, .8, 1),
                ),
                Mat4.compose(
                  const Vec3(.5, 0, 0),
                  Quat.identity,
                  const Vec3(.7, .8, 1),
                ),
              ]);
            }
            for (var i = 0; i < 4; i++) {
              await backend.render(captureTemporal(scene, camera));
            }
            mesh.setMorphWeight(0, .7);
            tip.quaternion = Quat.axisAngle(const Vec3(0, 0, 1), .5);
            if (mesh is InstancedMesh) mesh.setColor(1, const Color3(1, 0, 0));
            mesh.position = const Vec3(.6, 0, 0);
            final moved =
                await backend.render(captureTemporal(scene, camera))
                    as ReadbackOutput;
            final reference =
                await backend.render(captureTemporal(scene, camera, reset: 1))
                    as ReadbackOutput;
            // Interior pixels must follow the current pose. Edge coverage can differ
            // between jitter phases, so compare pixels whose 7x7 reference is flat.
            var compared = 0;
            for (var y = 3; y < 44; y++) {
              for (var x = 3; x < 44; x++) {
                final offset = (y * 47 + x) * 4;
                final flat = [
                  for (var yy = -3; yy <= 3; yy++)
                    for (var xx = -3; xx <= 3; xx++)
                      reference.image.pixels[((y + yy) * 47 + x + xx) * 4] -
                          reference.image.pixels[offset],
                ].every((d) => d.abs() < 3);
                if (!flat) continue;
                compared++;
                for (var c = 0; c < 4; c++) {
                  expect(
                    (moved.image.pixels[offset + c] -
                            reference.image.pixels[offset + c])
                        .abs(),
                    lessThanOrEqualTo(5),
                    reason:
                        'instance=$instanced alpha=$mode x=$x y=$y channel=$c',
                  );
                }
              }
            }
            expect(compared, greaterThan(600));
            expect(
              moved.stats.drawCalls,
              mode == MaterialAlphaMode.blend && instanced ? 5 : 4,
            );
          }
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'temporal view histories survive rejection and reset on resize, cut and disable',
    () async {
      final a = await NativeBackend.create(), b = a.createView();
      try {
        final scene = Scene()..add(Mesh(PlaneGeometry(), UnlitMaterial()));
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        final frozen = captureTemporal(scene, camera);
        final baseline = await a.render(frozen) as ReadbackOutput;
        final other = await b.render(frozen) as ReadbackOutput;
        expect(other.image.pixels, orderedEquals(baseline.image.pixels));
        for (var i = 0; i < 8; i++) {
          await a.render(frozen);
        }
        final steady = await a.temporalStats();
        expect(steady.historyViews, 2);
        for (var i = 0; i < 16; i++) {
          await a.render(frozen);
        }
        expect((await a.temporalStats()).residentBytes, steady.residentBytes);
        await expectLater(
          a.render(captureTemporal(scene, camera, maxBytes: 1)),
          throwsA(isA<SceneException>()),
        );
        expect((await a.temporalStats()).residentBytes, steady.residentBytes);
        await a.render(frozen);
        await a.render(captureTemporal(scene, camera, size: 31));
        await a.render(captureTemporal(scene, camera, enabled: false));
        final restarted = await a.render(frozen) as ReadbackOutput;
        expect(restarted.image.pixels, orderedEquals(baseline.image.pixels));
        camera.position = const Vec3(0, 0, 6);
        final cut =
            await a.render(captureTemporal(scene, camera)) as ReadbackOutput;
        final reset =
            await b.render(captureTemporal(scene, camera, reset: 5))
                as ReadbackOutput;
        expect(cut.image.pixels, orderedEquals(reset.image.pixels));
        await a.close();
        expect((await b.temporalStats()).historyViews, 1);
        await b.render(captureTemporal(scene, camera));
        await b.render(captureTemporal(scene, camera, enabled: false));
        expect((await b.temporalStats()).residentBytes, 0);
        expect((await b.temporalStats()).historyViews, 0);
      } finally {
        await a.close();
        await b.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}

FrameSubmission captureTemporal(
  Scene scene,
  Camera camera, {
  int size = 47,
  int reset = 0,
  int? maxBytes,
  bool enabled = true,
}) => FrameSubmission.capture(
  scene: scene,
  camera: camera,
  size: PhysicalSize(size, size),
  colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
  temporalAA: enabled
      ? TemporalAAOptions(maxBytes: maxBytes ?? 128 * 1024 * 1024)
      : null,
  temporalReset: reset,
);
