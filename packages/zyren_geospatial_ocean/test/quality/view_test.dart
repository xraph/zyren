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
    'view plans count installed passes and reject unsupported capture before allocation',
    () {
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 80),
        far: 200,
      );
      final quality = OceanRenderQuality.low.settings.copyWith(
        fftResolution: 4,
        segments: 4,
        maxPatches: 6,
        maxVertices: 150,
        maxScreenError: 100,
      );
      final config = OceanViewConfiguration(
        id: 'one',
        camera: camera,
        size: PhysicalSize(100, 60),
        ellipsoid: Ellipsoid(32, 32, 32),
        displacementBoundMetres: 0,
      );
      final plan = OceanViewSet.plan(settings: quality, views: [config]);
      expect(plan.views.single.geometryBytes, 6 * (25 * 40 + 16 * 24));
      expect(plan.views.single.materialBytes, 6 * (1104 + 3 * 256 * 16));
      expect(plan.activeEffects, {'surface'});
      expect(plan.additionalPayloads, isEmpty);
      final underwater = OceanViewConfiguration(
        id: 'two',
        camera: camera,
        size: PhysicalSize(100, 60),
        displacementBoundMetres: 0,
        underwater: OceanViewUnderwater(sampleCamera: (_, _) => null),
      );
      expect(
        () => OceanViewSet.plan(settings: quality, views: [underwater]),
        throwsA(isA<OceanQualityException>()),
      );
      expect(
        () => OceanViewSet.plan(settings: quality, views: [config, config]),
        throwsArgumentError,
      );
      expect(
        () => OceanViewSet.plan(
          settings: quality.copyWith(gpuBudgetBytes: 1),
          views: [config],
        ),
        throwsA(isA<ResourceException>()),
      );
    },
  );
  test(
    'native view recipes apply real LOD, optical work and morph transitions',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final ellipsoid = Ellipsoid(32, 32, 32);
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 80),
        near: .1,
        far: 200,
      );
      final size = PhysicalSize(48, 32);
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      var sampleAvailable = true;
      final config = OceanViewConfiguration(
        id: 'main',
        camera: camera,
        size: size,
        ellipsoid: ellipsoid,
        displacementBoundMetres: 0,
        underwater: OceanViewUnderwater(
          sampleCamera: (camera, frame) => !sampleAvailable
              ? null
              : OceanCameraWaterSample(
                  positionEcef: camera.position,
                  seconds: frame.seconds,
                  signedDistanceMetres: camera.position.length - 32,
                  upEcef: camera.position.normalized(),
                ),
        ),
        caustics: [
          OceanCausticRegion(
            id: 'floor',
            patch: OceanPatchId(face: 4, level: 0, x: 0, y: 0),
            extentMetres: 8,
            depthMetres: 2,
          ),
        ],
      );
      final low = OceanRenderQuality.low.settings.copyWith(
        fftResolution: 4,
        maxBands: 1,
        segments: 4,
        maxPatches: 6,
        maxVertices: 150,
        maxScreenError: 100,
      );
      final detailed = low.copyWith(
        fftResolution: 8,
        sceneInputScale: .75,
        ssrSteps: 16,
        shaftSteps: 12,
        causticResolution: 16,
        maxPatches: 24,
        maxVertices: 600,
        maxScreenError: .2,
      );
      OceanController<OceanViewSet>? controller;
      final state = fixtureSea(wind: 0);
      Future<ReadbackOutput> draw() async =>
          await backend.render(
                FrameSubmission.capture(
                  scene: scene,
                  camera: camera,
                  size: size,
                  colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
                ),
              )
              as ReadbackOutput;
      try {
        controller = await OceanController.create<OceanViewSet>(
          scope,
          state: state,
          chartIds: [0, 1, 2, 3, 4, 5],
          capabilities: backend.capabilities,
          quality: low,
          transitionDuration: const Duration(milliseconds: 100),
          plan: (q, previous) => OceanViewSet.plan(
            settings: q,
            views: [config],
            captureBackend: backend,
            previous: previous == null ? null : controller!.resources,
          ),
        );
        var view = controller.resources.view('main');
        expect(view.patchCount, 6);
        expect(view.vertexCount, 150);
        expect(
          view.water.every(
            (w) => w.reflections.mode == OceanReflectionMode.environment,
          ),
          isTrue,
        );
        expect(view.underwater!.settings.shaftSteps, 0);
        expect(view.caustics, isEmpty);
        view.attach(scene);
        expect(scene.renderSettings.opaqueCaptureScale, .5);
        final initial = (await draw()).image;
        expect(initial.pixels[(16 * 48 + 24) * 4 + 2], greaterThan(20));
        final stableAllocations =
            (await backend.resourceStats()).liveAllocations;
        sampleAvailable = false;
        await expectLater(controller.setQuality(detailed), throwsStateError);
        expect(controller.effectiveQuality, same(low));
        expect(controller.resources.view('main'), same(view));
        expect(view.isReady, isTrue);
        expect(scene.children.single, same(view.root));
        expect(
          (await backend.resourceStats()).liveAllocations,
          stableAllocations,
        );
        sampleAvailable = true;
        await controller.setQuality(detailed);
        view = controller.resources.view('main');
        expect(view.isMorphing, isTrue);
        expect(view.patchCount, greaterThan(6));
        expect(view.meshes.every((m) => m.morphWeights.single == 0), isTrue);
        expect(view.water.every((w) => w.reflections.stepLimit == 16), isTrue);
        expect(view.underwater!.settings.shaftSteps, 12);
        expect(view.caustics['floor']!.resolution, 16);
        expect(
          controller.activeEffects,
          containsAll(['underwater', 'caustics', 'screenSpaceReflection']),
        );
        view.attach(scene);
        expect(scene.children.length, 1);
        expect(scene.effects.length, 1);
        expect(scene.renderSettings.opaqueCaptureScale, .75);
        await controller.advance(
          seconds: .05,
          elapsed: const Duration(milliseconds: 50),
        );
        expect(view.meshes.every((m) => m.morphWeights.single == .5), isTrue);
        expect(view.caustics['floor']!.isCurrent, isTrue);
        await draw();
        expect(
          view.measurements.map((p) => p.name),
          containsAll([
            'main.boundary',
            'main.underwater.prepare',
            'main.caustics.floor',
          ]),
        );
        await controller.advance(
          seconds: .1,
          elapsed: const Duration(milliseconds: 100),
        );
        final finalView = controller.resources.view('main');
        expect(finalView.isMorphing, isFalse);
        expect(view.isClosed, isTrue);
        finalView.attach(scene);
        expect(scene.children.length, 1);
        expect(scene.effects.length, 1);
        await draw();
        expect(controller.seaStateRevision, state.revision);
        camera.position = const Vec3(0, 0, 140);
        await controller.rebuild();
        controller.resources.view('main').attach(scene);
        await controller.advance(
          seconds: .2,
          elapsed: const Duration(milliseconds: 200),
        );
        controller.resources.view('main').attach(scene);
        await draw();
        expect(controller.effectiveQuality, same(detailed));
        await controller.close();
        expect(scene.children, isEmpty);
        expect(scene.effects, isEmpty);
        expect(scene.renderSettings.opaqueCaptureScale, 1);
      } finally {
        await controller?.close();
        await scope.close();
        await draw();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
