import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean/src/surface/geometry.dart'
    show buildOceanPatchGeometry;
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';
import 'package:zyren_particles/ocean.dart';
import 'events_test.dart' show initial;

void main() {
  test(
    'native wake, debris, whitecap and coast fixtures save fixed-time captures',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final patch = OceanPatchId(face: 0, level: 15, x: 16384, y: 16384);
      final origin = patch.point(.5, .5);
      final basis = Ellipsoid.wgs84.eastNorthUpVectors(origin);
      Vec3 local(Vec3 p) =>
          origin + basis.east * p.x + basis.north * p.y + basis.up * p.z;
      final sun = (basis.east * -.2 + basis.north * .5 + basis.up).normalized();
      final scene = Scene()
        ..background = const Color3(.22, .35, .5)
        ..ambient = .35;
      scene.add(DirectionalLight(direction: -sun, intensity: 3));
      final camera = PerspectiveCamera(
        position: local(const Vec3(10, -14, 9)),
        target: local(const Vec3(-2, 0, 0)),
        up: basis.up,
        near: .1,
        far: 300,
      );
      final particles = ParticlePlugin(emitters: []);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [particles],
      );
      final frame = _Frame(
        EastNorthUpFrame(Ellipsoid.wgs84.fromEcef(origin)).matrix,
      );
      scene.add(frame);
      final boat = frame.add(Group());
      boat.add(
        Mesh(
          _hull(),
          StandardMaterial(
            baseColor: const Color3(.035, .18, .26),
            metallic: .25,
            roughness: .3,
          ),
        ),
      );
      boat.add(
        Mesh(
          BoxGeometry(width: 1.4, height: .85, depth: .65),
          StandardMaterial(
            baseColor: const Color3(.86, .88, .84),
            roughness: .4,
          ),
        )..position = const Vec3(-.3, 0, .52),
      );
      boat.add(
        Mesh(
          BoxGeometry(width: .95, height: .87, depth: .25),
          StandardMaterial(
            baseColor: const Color3(.025, .08, .12),
            metallic: .5,
            roughness: .15,
          ),
        )..position = const Vec3(-.25, 0, .61),
      );
      boat.add(
        Mesh(
          BoxGeometry(width: 1.5, height: .96, depth: .08),
          StandardMaterial(
            baseColor: const Color3(.92, .91, .85),
            roughness: .4,
          ),
        )..position = const Vec3(-.3, 0, .88),
      );
      final debris = frame.add(
        Mesh(
          BoxGeometry(width: .7, height: .35, depth: .2),
          StandardMaterial(
            baseColor: const Color3(.35, .13, .035),
            roughness: .8,
          ),
        )..position = const Vec3(3, -3, .1),
      );
      final ground = frame.add(
        Mesh(
          PlaneGeometry(width: 128, height: 128),
          UnlitMaterial(color: const Color3(.32, .3, .2)),
        )..position = const Vec3(0, 0, -12),
      );
      final field = await OceanInteractionField.create(
        owner,
        anchorEcef: origin,
        initialTime: initial,
        settings: OceanInteractionSettings(
          resolution: 128,
          extentMetres: 40,
          waveSpeed: 3,
          damping: .5,
          foamGain: 1,
          foamLifetimeSeconds: 5,
        ),
      );
      final spray = await OceanSprayParticles.create(
        particles.controller,
        anchor: origin,
        budget: 1024,
        maxEventsPerTick: 2,
        particlesPerEvent: 64,
        gravity: basis.up * -9.81,
      );
      final geometry = buildOceanPatchGeometry(
        patch,
        256,
        origin,
        (u, v) => local(Vec3((u - .5) * 100, (v - .5) * 100, 0)),
        Ellipsoid.wgs84,
      );
      final path = Platform.environment['OCEAN_CAPTURE_DIR'];
      final metadata = <String, Object?>{};
      Future<void> capture(String name, int tick) async {
        final output =
            await engine.renderFrame(
                  elapsed: Duration(
                    microseconds: (tick * 1000000 / 60).round(),
                  ),
                  width: 640,
                  height: 400,
                  colorPipeline: ColorPipeline(
                    toneMapping: ToneMapping.acesFilmic,
                    sampleCount: 4,
                  ),
                )
                as ReadbackOutput;
        final pixels = output.image.pixels;
        expect([
          for (var i = 3; i < pixels.length; i += 4) pixels[i],
        ], everyElement(255));
        metadata[name] = {
          'presentationTick': tick,
          'presentationSeconds': tick / 60,
          'interactionTick': field.time.tick,
          'interactionGeneration': field.time.generation,
          'waveSnapshotSeconds': 2,
          'fieldBytes': field.logicalBytes,
          'fieldDispatchesPerTick': field.dispatchesPerStep,
          'sprayCapacity': spray.isClosed ? 0 : spray.effectiveCapacity,
          'readbackBytes': pixels.length,
        };
        if (path != null) {
          await Directory(path).create(recursive: true);
          await File('$path/$name.ppm').writeAsBytes([
            ...ascii.encode('P6\n640 400\n255\n'),
            for (var i = 0; i < pixels.length; i += 4)
              ...pixels.sublist(i, i + 3),
          ]);
        }
      }

      OceanWaterMaterial? water;
      Mesh? mesh;
      try {
        for (final coast in [false, true]) {
          final state = OceanSeaState(
            seed: 42,
            canonicalResolution: 128,
            bands: [
              OceanWaveBand(
                patchMetres: 64,
                minWaveNumber: 0,
                maxWaveNumber: 2,
                windSpeed: coast ? 15 : 0,
                windHeadingRadians: .3,
                amplitude: .008,
                choppiness: .7,
              ),
            ],
          );
          final waves = await OceanWaveFieldGpu.create(
            owner,
            oceanChartSeaState(state, 0),
          );
          final packed = await OceanWaveRenderData.pack(
            owner,
            state: state,
            charts: {0: await waves.evaluate(2, resolution: 128)},
          );
          water = await OceanWaterMaterial.create(
            owner,
            waves: packed,
            patch: patch,
            geometrySpacingMetres: 100 / 256,
            interactions: field,
            lighting: OceanLighting(
              sunDirectionEcef: sun,
              sunIrradiance: const Vec3(3, 2.8, 2.5),
              skyRadiance: const Vec3(.3, .5, .8),
            ),
            optics: OceanOptics(roughness: .1),
            reflections: OceanReflectionSettings(
              stepLimit: 32,
              maximumDistanceMetres: 60,
            ),
          );
          mesh = scene.add(Mesh(geometry, water.material)..position = origin);
          if (!coast) {
            for (var tick = 1; tick <= 240; tick++) {
              boat.position = Vec3(
                -9 + tick / 60 * 3.5,
                0,
                .05 + .025 * math.sin(tick / 10),
              );
              final events = <OceanInteraction>[];
              if (tick % 2 == 0) {
                events.add(
                  OceanInteraction(
                    id: OceanInteractionId('vessel', tick),
                    time: initial.withTick(tick),
                    ecefPosition: local(
                      boat.position + const Vec3(-1.5, 0, -.05),
                    ),
                    relativeVelocity: basis.east * 3.5,
                    radiusMetres: 1.4,
                    energy: .004,
                  ),
                );
              }
              if (tick == 120) {
                events.add(
                  OceanInteraction(
                    id: OceanInteractionId('debris', 0),
                    time: initial.withTick(tick),
                    ecefPosition: local(const Vec3(3, -3, 0)),
                    relativeVelocity: Vec3.zero,
                    radiusMetres: 1.5,
                    energy: .09,
                  ),
                );
              }
              for (final e in events) {
                expect(field.enqueue(e), OceanInteractionAdmission.accepted);
              }
              await field.step(initial.withTick(tick));
              await spray.advance(
                tick,
                events: [
                  for (final e in events)
                    OceanSprayEvent(
                      source: e.id.source,
                      sequence: e.id.sequence,
                      tick: tick,
                      generation: 0,
                      position: e.ecefPosition + basis.up * .1,
                      velocity: e.relativeVelocity,
                      surfaceNormal: basis.up,
                      energy: e.energy,
                    ),
                ],
              );
              if (tick % 60 == 0 || (path != null && tick % 6 == 0)) {
                await capture('wake-${tick.toString().padLeft(3, '0')}', tick);
              }
            }
          } else {
            await spray.close();
            boat.visible = false;
            debris.visible = false;
            ground.visible = false;
            await field.reset(1);
            final center = Ellipsoid.wgs84.fromEcef(origin);
            final bathymetry = OceanFoamDepthMap(
              sourceId: 'owned.synthetic.coast',
              revision: 'v1',
              meanLevelMetres: 0,
              grid: GeoScalarGrid(
                width: 32,
                height: 32,
                bounds: GeographicRectangle(
                  center.longitude - .000004,
                  center.latitude - .000004,
                  center.longitude + .000004,
                  center.latitude + .000004,
                ),
                values: Float64List.fromList([
                  for (var y = 0; y < 32; y++)
                    for (var x = 0; x < 32; x++) y > 18 ? .5 : 5,
                ]),
              ),
            );
            final shelf = frame.add(
              Mesh(
                PlaneGeometry(width: 40, height: 20),
                UnlitMaterial(color: const Color3(.52, .42, .25)),
              )..position = const Vec3(0, 10, -.5),
            );
            final source = await OceanFoamProducer.create(
              owner,
              water: water,
              field: field,
              depth: bathymetry,
              settings: OceanFoamSettings(
                compressionThreshold: .98,
                whitecapRate: 2,
                shoreRate: 2,
              ),
            );
            await source.update();
            for (var tick = 1; tick <= 120; tick++) {
              await field.step(initial.withTick(tick).withGeneration(1));
            }
            await capture('whitecaps-coast', 420);
            final debug = await OceanWaterMaterial.create(
              owner,
              waves: packed,
              patch: patch,
              geometrySpacingMetres: 100 / 256,
              interactions: field,
              debug: OceanWaterDebug.foam,
            );
            mesh.material = debug.material;
            await capture('whitecaps-coast-foam', 421);
            await debug.close();
            await source.close();
            frame.remove(shelf);
          }
          scene.remove(mesh);
          await water.close();
          await packed.close();
          await waves.close();
        }
        if (path != null) {
          await File(
            '$path/captures.json',
          ).writeAsString(const JsonEncoder.withIndent('  ').convert(metadata));
        }
      } finally {
        if (mesh != null) scene.remove(mesh);
        await spray.close();
        await owner.close();
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

extension on GeoInstant {
  GeoInstant withGeneration(int generation) => GeoInstant(
    tick: tick,
    hz: hz,
    epoch: epoch,
    generation: generation,
    standard: standard,
  );
}

class _Frame extends Group {
  final Mat4 matrix;
  _Frame(this.matrix);
  @override
  Mat4 get localMatrix => matrix;
}

BufferGeometry _hull() {
  final rim = [
    const Vec3(-1.6, -.65, .22),
    const Vec3(.9, -.65, .22),
    const Vec3(1.8, 0, .22),
    const Vec3(.9, .65, .22),
    const Vec3(-1.6, .65, .22),
  ];
  final keel = [for (final p in rim) Vec3(p.x * .85, p.y * .5, -.35)];
  final positions = <double>[], normals = <double>[], indices = <int>[];
  void triangle(Vec3 a, Vec3 b, Vec3 c) {
    final normal = (b - a).cross(c - a).normalized(),
        index = positions.length ~/ 3;
    for (final p in [a, b, c]) {
      positions.addAll(p.storage);
      normals.addAll(normal.storage);
    }
    indices.addAll([index, index + 1, index + 2]);
  }

  for (var i = 0; i < 5; i++) {
    final j = (i + 1) % 5;
    triangle(rim[i], keel[i], keel[j]);
    triangle(rim[i], keel[j], rim[j]);
    triangle(const Vec3(0, 0, .22), rim[i], rim[j]);
    triangle(const Vec3(0, 0, -.35), keel[j], keel[i]);
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
  );
}
