import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'expanded native ocean applies layers, recovers failed quality and retires 100 resizes',
    () async {
      final backend = await NativeBackend.create();
      final ellipsoid = Ellipsoid(32, 32, 32);
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 80),
        near: .1,
        far: 200,
      );
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final state = fixtureSea(wind: 0);
      final quality = OceanRenderQuality.low.settings.copyWith(
        fftResolution: 4,
        maxBands: 1,
        segments: 4,
        maxPatches: 6,
        maxVertices: 150,
        maxScreenError: 100,
      );
      late OceanNativePresentation presentation;
      final ocean = OceanExtension(
        state: state,
        createSampler: (context) => OceanSamplerCpu.create(
          state: state,
          frame: context.worldFrame,
          now: () => context.clock.instant,
          coverage: const OceanAllWaterCoverage(),
        ),
        createPresentation: (context, sampler) =>
            presentation = OceanNativePresentation(
              context: context,
              state: state,
              quality: quality,
              hasUnderwater: true,
              transitionDuration: Duration.zero,
              configureView: (frame) => OceanViewConfiguration(
                id: 'main',
                camera: context.sceneContext.camera,
                size: PhysicalSize(frame.width, frame.height),
                ellipsoid: ellipsoid,
                displacementBoundMetres: 0,
                underwater: OceanViewUnderwater(
                  sampleCamera: (camera, frame) async {
                    final instant = context.clock.instant.withTick(
                      (frame.seconds * context.clock.hz).round(),
                    );
                    final sample = (await sampler.sampleBatch([
                      OceanQuery(camera.position, instant),
                    ], OceanQueryPolicy())).single;
                    if (!sample.available) return null;
                    final surface = sample.value!;
                    return OceanCameraWaterSample(
                      positionEcef: camera.position,
                      upEcef: surface.normalEcef,
                      seconds: frame.seconds,
                      signedDistanceMetres:
                          (camera.position - surface.positionEcef).dot(
                            surface.normalEcef,
                          ),
                    );
                  },
                ),
              ),
            ),
      );
      final host = GeospatialPlugin(ellipsoid: ellipsoid, extensions: [ocean]);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: host.scenePlugins,
      );
      var elapsed = 0;
      Future<RenderedFrame> draw(int width) => engine.render(
        elapsed: Duration(milliseconds: elapsed += 16),
        width: width,
        height: 16,
      );
      try {
        await draw(24);
        expect(presentation.isReady, isTrue);
        expect(scene.effects, hasLength(1));
        final first = presentation.view!;
        host.layers.setVisible(ocean.surfaceLayerId, false);
        host.layers.setVisible(ocean.foamLayerId, false);
        await draw(24);
        expect(first.root.visible, isFalse);
        expect(first.water.every((w) => !w.foamEnabled), isTrue);
        expect(scene.effects, hasLength(1));
        expect(host.clock.tick, 0);
        host.layers.setVisible(ocean.underwaterLayerId, false);
        await draw(24);
        expect(scene.effects, isEmpty);
        host.layers.setVisible(ocean.surfaceLayerId, true);
        host.layers.setVisible(ocean.underwaterLayerId, true);
        await draw(24);
        expect(scene.effects, hasLength(1));
        presentation.requestQuality(quality.copyWith(gpuBudgetBytes: 1));
        await expectLater(draw(24), throwsA(anything));
        expect(presentation.view, same(first));
        expect(first.isReady, isTrue);
        expect(
          host.layers.layer(ocean.surfaceLayerId).status.data,
          GeoLayerDataState.failed,
        );
        await draw(24);
        expect(
          host.layers.layer(ocean.surfaceLayerId).status.data,
          GeoLayerDataState.ready,
        );
        presentation.requestQuality(quality.copyWith(fftResolution: 8));
        await draw(24);
        expect(presentation.controller!.waves.resolution, 8);
        final counters = <int, (int, int, int, int)>{};
        for (var i = 0; i < 100; i++) {
          final width = i.isEven ? 32 : 24;
          await draw(width);
          final stats = await backend.resourceStats();
          final measured = (
            stats.liveAllocations,
            stats.residentBytes,
            (await backend.graphStats()).liveGraphs,
            (await backend.graphStats()).liveMeshShaders,
          );
          if (counters.containsKey(width)) {
            expect(measured, counters[width]);
          } else {
            counters[width] = measured;
          }
          expect(scene.children, hasLength(1));
          expect(scene.effects, hasLength(1));
          expect(presentation.controller!.seaStateRevision, state.revision);
        }
        print('Ocean native resize counters: $counters');
        await engine.dispose();
        expect(scene.children, isEmpty);
        expect(scene.effects, isEmpty);
        expect(host.layers.snapshot, isEmpty);
        expect(host.registry.find(oceanSampler), isNull);
        final stats = await backend.resourceStats();
        expect(stats.liveAllocations, 0);
        expect((await backend.graphStats()).liveGraphs, 0);
        expect((await backend.graphStats()).liveMeshShaders, 0);
      } finally {
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
