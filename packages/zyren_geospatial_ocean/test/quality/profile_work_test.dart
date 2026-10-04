import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_particles/zyren_particles.dart';
import 'package:zyren_particles/ocean.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

typedef _Presentation = ({OceanWaterMaterial water, OceanSprayParticles spray});

void main() {
  test(
    'each stock profile allocates its native wave grid and optional spray cap',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final plugin = ParticlePlugin(emitters: []);
      final patch = OceanPatchId(face: 4, level: 16, x: 32768, y: 32768);
      final origin = patch.point(.5, .5);
      final scene = Scene();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(
          position: origin + const Vec3(0, 0, 20),
          target: origin,
          near: .1,
          far: 100,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      final state = fixtureSea(resolution: 512);
      final geometry = OceanPatchGeometry(
        patch,
        origin,
        PlaneGeometry(width: 20, height: 20),
      );
      final report = <Map<String, Object?>>[];
      OceanController<_Presentation>? controller;
      var elapsed = 0;
      try {
        for (final profile in OceanRenderQuality.values) {
          final quality = profile.settings;
          final sprayBytes = OceanSprayParticles.estimateBytes(
            budget: quality.sprayParticleCap,
          );
          controller = await OceanController.create<_Presentation>(
            scope,
            state: state,
            chartIds: [4],
            capabilities: backend.capabilities,
            quality: quality,
            transitionDuration: Duration.zero,
            plan: (settings, previous) => OceanQualityPlan(
              views: [
                OceanViewAllocation(
                  id: 'surface',
                  size: PhysicalSize(32, 32),
                  materialBytes: 1104,
                  geometryBytes: geometry.geometry.capture().gpuByteLength,
                ),
              ],
              additionalPayloads: {'spray': sprayBytes},
              activeEffects: {
                'surface',
                if (quality.sprayParticleCap > 0) 'spray',
              },
              build: (context, waves) async {
                final water = await OceanWaterMaterial.create(
                  context.gpu,
                  waves: waves,
                  patch: patch,
                  geometrySpacingMetres: 1,
                  reflections: settings.reflections,
                );
                context.onClose(water.close);
                final spray = await OceanSprayParticles.create(
                  plugin.controller,
                  autoAttach: false,
                  budget: settings.sprayParticleCap,
                  initialTick: 60,
                  generation: 2,
                  particlesPerEvent: 4,
                  anchor: origin,
                  maxLogicalBytes: settings.gpuBudgetBytes,
                  retainedBytes:
                      OceanWaveStream.estimateBytes(
                        settings.fftResolution,
                        1,
                        1,
                      ) +
                      1104,
                );
                context.onClose(spray.close);
                return (water: water, spray: spray);
              },
            ),
          );
          expect(scene.children, isEmpty);
          final resources = controller.resources;
          final mesh = scene.add(resources.water.createMesh(geometry));
          for (final object in resources.spray.objects) {
            scene.add(object);
          }
          expect(resources.spray.logicalBytes, sprayBytes);
          expect(resources.spray.effectiveCapacity, quality.sprayParticleCap);
          expect(controller.waves.resolution, quality.fftResolution);
          expect(controller.waves.bandCount, 1);
          expect(
            resources.water.reflections.mode,
            quality.ssrSteps == 0
                ? OceanReflectionMode.environment
                : OceanReflectionMode.screenSpace,
          );
          if (quality.ssrSteps > 0) {
            expect(resources.water.reflections.stepLimit, quality.ssrSteps);
          }
          await controller.advance(
            seconds: .25,
            elapsed: Duration(milliseconds: elapsed += 250),
          );
          final admissions = await resources.spray.advance(
            61,
            events: [
              for (var i = 0; i < 8; i++)
                OceanSprayEvent(
                  source: 'hull-$i',
                  sequence: 0,
                  tick: 61,
                  generation: 2,
                  position: origin + Vec3(i.toDouble() - 4, 0, 0),
                  velocity: Vec3.zero,
                  surfaceNormal: const Vec3(0, 0, 1),
                  energy: 1,
                ),
            ],
          );
          expect(
            admissions.every(
              (a) =>
                  a ==
                  (quality.sprayParticleCap == 0
                      ? OceanSprayAdmission.disabled
                      : OceanSprayAdmission.accepted),
            ),
            isTrue,
          );
          scene.renderSettings = quality.applyTo(scene.renderSettings);
          final frame = await engine.render(
            elapsed: Duration(milliseconds: elapsed),
            width: 32,
            height: 32,
          );
          expect(frame.pixels[(16 * 32 + 16) * 4 + 2], greaterThan(10));
          final particles = [
            for (final name in resources.spray.emitterNames)
              ...await plugin.controller.inspect(name),
          ];
          expect(particles.length, quality.sprayParticleCap == 0 ? 0 : 32);
          report.add({
            'profile': profile.name,
            'renderResolution': controller.waves.resolution,
            'renderBands': controller.waves.bandCount,
            'waveDispatches': controller.diagnostics().passes.first.dispatches,
            'candidatePayloadBytes': controller.estimatedBytes,
            'sprayCapacity': resources.spray.effectiveCapacity,
            'sprayPayloadBytes': sprayBytes,
          });
          scene.remove(mesh);
          await controller.close();
          expect(plugin.controller.names, isEmpty);
          await engine.render(
            elapsed: Duration(milliseconds: ++elapsed),
            width: 32,
            height: 32,
          );
          expect((await backend.resourceStats()).liveAllocations, 0);
        }
        print(jsonEncode({'profiles': report, 'physicalGpuResidency': null}));
      } finally {
        await controller?.close();
        await engine.dispose();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
