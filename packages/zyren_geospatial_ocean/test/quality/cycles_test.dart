import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';

void main() {
  test(
    '100 native quality fades across two views return to stable resource counts',
    () async {
      final backend = await NativeBackend.create();
      final secondBackend = backend.createView();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea(wind: 0);
      final cameras = [
        PerspectiveCamera(position: const Vec3(0, 0, 80), near: .1, far: 200),
        PerspectiveCamera(position: const Vec3(80, 0, 0), near: .1, far: 200),
      ];
      final sizes = [PhysicalSize(24, 16), PhysicalSize(16, 24)];
      final scenes = [Scene(), Scene()];
      final configs = [
        for (var i = 0; i < 2; i++)
          OceanViewConfiguration(
            id: 'view-$i',
            camera: cameras[i],
            size: sizes[i],
            ellipsoid: Ellipsoid(32, 32, 32),
            displacementBoundMetres: 0,
          ),
      ];
      final low = OceanRenderQuality.low.settings.copyWith(
        fftResolution: 4,
        maxBands: 1,
        maxPatches: 6,
        maxVertices: 150,
        segments: 4,
        maxScreenError: 100,
      );
      final high = low.copyWith(
        fftResolution: 8,
        sceneInputScale: .75,
        ssrSteps: 16,
      );
      OceanController<OceanViewSet>? controller;
      Future<void> draw([bool expectWater = true]) async {
        for (var i = 0; i < 2; i++) {
          final output =
              await (i == 0 ? backend : secondBackend).render(
                    FrameSubmission.capture(
                      scene: scenes[i],
                      camera: cameras[i],
                      size: sizes[i],
                      colorPipeline: ColorPipeline(
                        toneMapping: ToneMapping.linear,
                      ),
                    ),
                  )
                  as ReadbackOutput;
          if (expectWater) {
            final center =
                (sizes[i].height ~/ 2 * sizes[i].width + sizes[i].width ~/ 2) *
                4;
            expect(output.image.pixels[center + 2], greaterThan(20));
          }
        }
      }

      void attach() {
        for (var i = 0; i < 2; i++) {
          controller!.resources.view('view-$i').attach(scenes[i]);
        }
      }

      final baseline = <int, List<int>>{};
      try {
        controller = await OceanController.create<OceanViewSet>(
          scope,
          state: state,
          chartIds: [0, 1, 2, 3, 4, 5],
          capabilities: backend.capabilities,
          quality: low,
          transitionDuration: const Duration(milliseconds: 2),
          plan: (q, previous) => OceanViewSet.plan(
            settings: q,
            views: configs,
            previous: previous == null ? null : controller!.resources,
          ),
        );
        attach();
        await draw();
        for (var cycle = 0; cycle < 100; cycle++) {
          final quality = cycle.isEven ? high : low;
          await controller.setQuality(quality);
          attach();
          await controller.advance(
            seconds: (cycle * 2 + 1) / 1000,
            elapsed: Duration(milliseconds: cycle * 2 + 1),
          );
          await draw();
          await controller.advance(
            seconds: (cycle * 2 + 2) / 1000,
            elapsed: Duration(milliseconds: cycle * 2 + 2),
          );
          attach();
          await draw();
          final resources = await backend.resourceStats();
          final graphs = await backend.graphStats();
          final shaders = await backend.shaderStats();
          final counters = [
            resources.liveAllocations,
            resources.residentBytes,
            graphs.liveGraphs,
            graphs.liveMeshShaders,
            graphs.meshPipelines,
            shaders.livePrograms,
            shaders.cachedModules,
          ];
          baseline.putIfAbsent(quality.fftResolution, () => counters);
          expect(
            counters,
            baseline[quality.fftResolution],
            reason: 'cycle $cycle',
          );
          expect(controller.resources.patchCount, 12);
          expect(controller.seaStateRevision, state.revision);
          expect(controller.retirementFailures, isEmpty);
        }
        print(
          jsonEncode({
            'cycles': 100,
            'views': 2,
            'charts': 6,
            'counters': [
              'registryAllocations',
              'registryPayloadBytes',
              'liveGraphs',
              'meshBindings',
              'meshPipelines',
              'liveShaderModules',
              'cachedShaderModules',
            ],
            'stableProfiles': {
              for (final e in baseline.entries) '${e.key}': e.value,
            },
          }),
        );
        await controller.close();
        await draw(false);
        expect((await backend.resourceStats()).liveAllocations, 0);
        expect((await backend.graphStats()).liveGraphs, 0);
        expect((await backend.graphStats()).liveMeshShaders, 0);
        expect((await backend.shaderStats()).livePrograms, 0);
      } finally {
        await controller?.close();
        await scope.close();
        await secondBackend.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
