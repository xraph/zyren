import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren/rendering.dart';
import 'underwater_test.dart' show srgb;
import '../support/sea_states.dart';
import 'surface_capture_test.dart' show half;

void main() {
  test(
    'native projected caustics conserve bounded flux and change real resolution',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
      final origin = patch.point(.5, .5);
      final up = origin.normalized();
      try {
        for (final wind in [0.0, 12.0]) {
          final state = fixtureSea(wind: wind);
          final field = await OceanWaveFieldGpu.create(
            scope,
            oceanChartSeaState(state, 4),
          );
          final waves = await OceanWaveRenderData.pack(
            scope,
            state: state,
            charts: {4: await field.evaluate(1, resolution: 8)},
          );
          for (final night in [false, true]) {
            final water = await OceanWaterMaterial.create(
              scope,
              waves: waves,
              patch: patch,
              geometrySpacingMetres: .1,
              optics: OceanOptics(
                absorptionPerMetre: const Vec3(.1, .2, .3),
                scatteringPerMetre: Vec3.zero,
              ),
              lighting: OceanLighting(sunDirectionEcef: up * (night ? -1 : 1)),
            );
            int? previousBytes;
            for (final resolution in [16, 32]) {
              final caustics = (await OceanCaustics.create(
                scope,
                water: water,
                settings: OceanUnderwaterSettings(
                  causticResolution: resolution,
                ),
                extentMetres: 32,
                depthMetres: 2,
              ))!;
              expect(caustics.resolution, resolution);
              expect(
                (caustics.texture.descriptor as TextureDescriptor).width,
                resolution,
              );
              if (previousBytes != null) {
                expect(caustics.logicalBytes, greaterThan(previousBytes * 3));
              }
              previousBytes = caustics.logicalBytes;
              final readScope = scope.createChild();
              final retained = await readScope.resources.retain(
                caustics.texture,
              );
              final bytes = ByteData.sublistView(
                await readScope.resources.readTexture(retained),
              );
              for (var c = 0; c < 3; c++) {
                final values = [
                  for (var i = 0; i < resolution * resolution; i++)
                    half(bytes.getUint16(i * 8 + c * 2, Endian.little)),
                ];
                expect(
                  values.every((v) => v.isFinite && v >= 0 && v <= 4.001),
                  isTrue,
                );
                final mean = values.reduce((a, b) => a + b) / values.length;
                expect(mean, lessThanOrEqualTo(night ? 0 : 1.001));
                if (wind == 0 && !night) {
                  final expected =
                      (1 - waterFresnel(1, 1, 1.333)) *
                      math.exp(-2 * [.1, .2, .3][c]);
                  expect(mean, closeTo(expected, .002));
                }
                if (wind != 0 && !night) {
                  expect(
                    values.reduce(math.max) - values.reduce(math.min),
                    greaterThan(.001),
                  );
                }
              }
              final receiverScope = scope.createChild(
                label: 'caustic-receiver-test',
              );
              final material = await caustics.createReceiverMaterial(
                receiverScope,
                albedo: const Color3(.2, .2, .2),
              );
              final positions = <double>[];
              for (final uv in [
                (-16.0, -16.0),
                (16.0, -16.0),
                (16.0, 16.0),
                (-16.0, 16.0),
              ]) {
                positions.addAll(
                  (caustics.east * uv.$1 +
                          caustics.north * uv.$2 -
                          caustics.up * 2)
                      .storage,
                );
              }
              final scene = Scene()
                ..add(
                  Mesh(
                    BufferGeometry(
                      positions: positions,
                      normals: [
                        for (var i = 0; i < 4; i++) ...caustics.up.storage,
                      ],
                      indices: [0, 1, 2, 0, 2, 3],
                    ),
                    material,
                  )..position = caustics.anchorEcef,
                );
              final camera = PerspectiveCamera(
                position: caustics.anchorEcef + caustics.up * 3,
                target: caustics.anchorEcef - caustics.up * 2,
                up: caustics.north,
                near: .1,
                far: 20,
              );
              final image =
                  await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(32, 32),
                          colorPipeline: ColorPipeline(
                            toneMapping: ToneMapping.linear,
                          ),
                        ),
                      )
                      as ReadbackOutput;
              final color = image.image.pixels.sublist(
                (16 * 32 + 16) * 4,
                (16 * 32 + 16) * 4 + 4,
              );
              if (night) {
                expect(color, [0, 0, 0, 255]);
              }
              if (!night && wind == 0) {
                for (var c = 0; c < 3; c++) {
                  final factor =
                      (1 - waterFresnel(1, 1, 1.333)) *
                      math.exp(-2 * [.1, .2, .3][c]);
                  expect(
                    color[c],
                    closeTo(srgb(.2 * [4, 3.8, 3.5][c] * factor / math.pi), 2),
                  );
                }
              }
              await receiverScope.close();
              await caustics.close();
              await readScope.close();
            }
            expect(
              await OceanCaustics.create(
                scope,
                water: water,
                settings: OceanUnderwaterSettings(causticResolution: 0),
                extentMetres: 32,
                depthMetres: 2,
              ),
              isNull,
            );
            if (wind == 0 && !night) {
              final shadowScope = scope.createChild();
              final shadow = await shadowScope.resources.createTexture(
                TextureDescriptor(
                  width: 1,
                  height: 1,
                  format: TextureFormat.rgba32Float,
                  usage: {TextureUsage.sampled, TextureUsage.copyDestination},
                ),
              );
              await shadowScope.resources.writeTexture(
                shadow,
                Float32List(4).buffer.asUint8List(),
              );
              final masked = (await OceanCaustics.create(
                scope,
                water: water,
                settings: OceanUnderwaterSettings(causticResolution: 16),
                extentMetres: 32,
                depthMetres: 2,
                visibility: OceanSunVisibility(
                  texture: shadow,
                  anchor: origin,
                  uPerMetre: const Vec3(.01, 0, 0),
                  vPerMetre: const Vec3(0, .01, 0),
                ),
              ))!;
              expect(masked.hasShadowVisibility, isTrue);
              final retained = await shadowScope.resources.retain(
                masked.texture,
              );
              final bytes = ByteData.sublistView(
                await shadowScope.resources.readTexture(retained),
              );
              for (var i = 0; i < 256; i++) {
                for (var c = 0; c < 3; c++) {
                  expect(
                    half(bytes.getUint16(i * 8 + c * 2, Endian.little)),
                    0,
                  );
                }
              }
              await masked.close();
              await shadowScope.close();
              await expectLater(
                OceanCaustics.create(
                  scope,
                  water: water,
                  settings: OceanUnderwaterSettings(causticResolution: 16),
                  extentMetres: 32,
                  depthMetres: 2,
                  maxLogicalBytes: 1,
                ),
                throwsA(isA<ResourceException>()),
              );
            }
            await water.close();
          }
          await waves.close();
          await field.close();
        }
      } finally {
        await scope.close();
        await backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(8, 8),
          ),
        );
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
