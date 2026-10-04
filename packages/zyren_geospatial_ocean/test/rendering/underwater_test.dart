import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native underwater clips water distance and atomically replaces effects',
    () async {
      final backend = await NativeBackend.create(
        experimentalAppleSurfaces: true,
      );
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea(wind: 0);
      final field = await OceanWaveFieldGpu.create(
        scope,
        oceanChartSeaState(state, 4),
      );
      final waves = await OceanWaveRenderData.pack(
        scope,
        state: state,
        charts: {4: await field.evaluate(0, resolution: 8)},
      );
      final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
      final origin = patch.point(.5, .5);
      final water = await OceanWaterMaterial.create(
        scope,
        waves: waves,
        patch: patch,
        geometrySpacingMetres: .1,
      );
      final waterMesh = Mesh(
        PlaneGeometry(width: 20, height: 20),
        water.material,
      )..position = origin;
      final size = PhysicalSize(32, 32);
      final capture = await OceanSurfaceCapture.create(
        scope,
        backend,
        draws: [OceanBoundaryDraw(water: water, mesh: waterMesh)],
        size: size,
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(backgroundAlpha: 0, hdr: true);
      final floor = scene.add(
        Mesh(
          PlaneGeometry(width: 20, height: 20),
          UnlitMaterial(
            color: const Color3(1, 1, 1),
            side: MaterialSide.doubleSided,
          ),
        )..position = origin - const Vec3(0, 0, 3),
      );
      final optics = OceanOptics(
        absorptionPerMetre: const Vec3(1, .5, .25),
        scatteringPerMetre: Vec3.zero,
      );
      final dark = OceanLighting(
        sunIrradiance: Vec3.zero,
        skyRadiance: Vec3.zero,
      );
      OceanUnderwaterPass? active;
      Future<List<int>> draw(Camera camera) async {
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: size,
                    colorPipeline: ColorPipeline(
                      toneMapping: ToneMapping.linear,
                    ),
                  ),
                )
                as ReadbackOutput;
        return output.image.pixels.sublist(
          (16 * 32 + 16) * 4,
          (16 * 32 + 16) * 4 + 4,
        );
      }

      try {
        for (final perspective in [false, true]) {
          for (final reversed in [false, true]) {
            final camera = perspective
                ? PerspectiveCamera(
                    position: origin - const Vec3(0, 0, 1),
                    target: floor.position,
                    near: .1,
                    far: 20,
                  )
                : OrthographicCamera(
                    position: origin - const Vec3(0, 0, 1),
                    target: floor.position,
                    near: .1,
                    far: 20,
                    verticalSize: 4,
                  );
            camera.depthStrategy = reversed
                ? DepthStrategy.reversed
                : DepthStrategy.standard;
            await capture.update(camera);
            final pass = await OceanUnderwaterPass.create(
              scope,
              surface: capture,
              optics: optics,
              lighting: dark,
            );
            await pass.prepare(
              camera: camera,
              viewport: size,
              signedSurfaceDistance: -1,
              surfaceUp: const Vec3(0, 0, 1),
            );
            pass.attach(scene);
            await active?.close();
            active = pass;
            expect(scene.effects.length, 1);
            final result = await draw(camera);
            for (var c = 0; c < 3; c++) {
              expect(
                result[c],
                closeTo(srgb(math.exp(-[1, .5, .25][c] * 2)), 2),
              );
            }
            pass.detach();
            expect(scene.effects, isEmpty);
            expect(await draw(camera), [255, 255, 255, 255]);
            pass.attach(scene);
            expect(await draw(camera), result);
            floor.visible = false;
            expect(await draw(camera), [0, 0, 0, 0]);
            floor.visible = true;
            // The configured pool ends one metre into this two metre view ray.
            final bounded = await OceanUnderwaterPass.create(
              scope,
              surface: capture,
              optics: optics,
              lighting: dark,
              volume: OceanWaterVolume.box(
                min: origin + const Vec3(-5, -5, -2),
                max: origin + const Vec3(5, 5, 0),
              ),
            );
            await bounded.prepare(
              camera: camera,
              viewport: size,
              signedSurfaceDistance: -1,
              surfaceUp: const Vec3(0, 0, 1),
            );
            bounded.attach(scene);
            await active.close();
            active = bounded;
            final clipped = await draw(camera);
            for (var c = 0; c < 3; c++) {
              expect(clipped[c], closeTo(srgb(math.exp(-[1, .5, .25][c])), 2));
            }
            expect(scene.effects.length, 1);
          }
        }
        final camera = OrthographicCamera(
          position: origin - const Vec3(0, 0, 1),
          target: floor.position,
          near: .1,
          far: 20,
          verticalSize: 4,
        );
        await capture.update(camera);
        floor.material = UnlitMaterial(color: const Color3(0, 0, 0));
        final shadow = await scope.resources.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await scope.resources.writeTexture(
          shadow,
          Float32List(4).buffer.asUint8List(),
        );
        for (final mode in ['day', 'disabled', 'shadow', 'night', 'rotated']) {
          final stepCount = mode == 'disabled' ? 0 : 64;
          final pass = await OceanUnderwaterPass.create(
            scope,
            surface: capture,
            optics: OceanOptics(
              absorptionPerMetre: Vec3.zero,
              scatteringPerMetre: const Vec3(.2, .3, .4),
            ),
            settings: OceanUnderwaterSettings(shaftSteps: stepCount),
            worldToEcef: mode == 'rotated'
                ? Mat4.compose(
                    Vec3.zero,
                    Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
                    Vec3.one,
                  )
                : null,
            lighting: OceanLighting(
              sunDirectionEcef: mode == 'rotated'
                  ? const Vec3(1, 0, 0)
                  : Vec3(0, 0, mode == 'night' ? -1 : 1),
              sunIrradiance: const Vec3(4, 4, 4),
              skyRadiance: Vec3.zero,
            ),
            sunVisibility: mode != 'shadow'
                ? null
                : OceanSunVisibility(
                    texture: shadow,
                    anchor: origin,
                    uPerMetre: const Vec3(.1, 0, 0),
                    vPerMetre: const Vec3(0, .1, 0),
                  ),
          );
          expect(pass.hasShadowVisibility, mode == 'shadow');
          await pass.prepare(
            camera: camera,
            viewport: size,
            signedSurfaceDistance: -1,
            surfaceUp: const Vec3(0, 0, 1),
          );
          pass.attach(scene);
          await active?.close();
          active = pass;
          final result = await draw(camera);
          if (mode == 'day' || mode == 'rotated') {
            for (var c = 0; c < 3; c++) {
              final extinction = [.2, .3, .4][c];
              final expected =
                  4 /
                  (4 * math.pi) *
                  (1 - waterFresnel(1, 1, 1.333)) *
                  .5 *
                  math.exp(-extinction) *
                  (1 - math.exp(-4 * extinction));
              expect(result[c], closeTo(srgb(expected), 2));
            }
          } else {
            expect(result, [0, 0, 0, 255]);
          }
        }
        // A horizontal orthographic view has ray origins on both sides of
        // the waterline. The optical pass must not use one global wet flag.
        floor.position = origin + const Vec3(4, 0, 0);
        floor.lookAt(origin);
        floor.material = UnlitMaterial(
          color: const Color3(1, 1, 1),
          side: MaterialSide.doubleSided,
        );
        final halfCamera = OrthographicCamera(
          position: origin,
          target: floor.position,
          up: const Vec3(0, 0, 1),
          near: .1,
          far: 20,
          verticalSize: 4,
        );
        await capture.update(halfCamera);
        final halfPass = await OceanUnderwaterPass.create(
          scope,
          surface: capture,
          optics: optics,
          lighting: dark,
        );
        await halfPass.prepare(
          camera: halfCamera,
          viewport: size,
          signedSurfaceDistance: 0,
          surfaceUp: const Vec3(0, 0, 1),
        );
        halfPass.attach(scene);
        await active?.close();
        active = halfPass;
        final halfFrame =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: halfCamera,
                    size: size,
                    colorPipeline: ColorPipeline(
                      toneMapping: ToneMapping.linear,
                    ),
                  ),
                )
                as ReadbackOutput;
        List<int> row(int y) => halfFrame.image.pixels.sublist(
          (y * 32 + 16) * 4,
          (y * 32 + 16) * 4 + 4,
        );
        expect(row(8), [255, 255, 255, 255]);
        final lower = row(24);
        for (var c = 0; c < 3; c++) {
          expect(lower[c], closeTo(srgb(math.exp(-4 * [1, .5, .25][c])), 2));
        }
      } finally {
        await active?.close();
        await capture.close();
        await scope.close();
        scene.remove(floor);
        await draw(PerspectiveCamera());
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}

int srgb(double value) =>
    (255 *
            (value <= .0031308
                ? 12.92 * value
                : 1.055 * math.pow(value, 1 / 2.4) - .055))
        .round();
