import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

final class FixturePresentation implements OceanPresentation {
  @override
  bool hasUnderwater = true;
  @override
  bool isReady = true;
  bool closed = false, fail = false;
  final frames = <(GeoInstant, OceanLayerVisibility)>[];
  @override
  Future<void> prepare(
    GeoInstant instant,
    FrameInfo frame,
    OceanLayerVisibility visibility,
  ) async {
    if (fail) throw StateError('presentation fixture failure');
    frames.add((instant, visibility));
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class FixtureRenderer implements SceneRenderer {
  @override
  final capabilities = RendererCapabilities(
    name: 'lifecycle fixture',
    features: {},
    maxDimension: 64,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}

Future<SceneEngine> engine(
  List<ScenePlugin> plugins, {
  AttachmentScope? lifetime,
}) => SceneEngine.create(
  scene: Scene(),
  camera: PerspectiveCamera(),
  plugins: plugins,
  lifetime: lifetime,
  rendererFactory: () async => FixtureRenderer(),
);
void main() {
  final state = fixtureSea(wind: 0);
  OceanSampler? sampler;
  Future<OceanSampler> createSampler(GeospatialContext context) async =>
      sampler = await OceanSamplerCpu.create(
        state: state,
        frame: context.worldFrame,
        now: () => context.clock.instant,
        coverage: const OceanAllWaterCoverage(),
      );
  test(
    'expanded host publishes scoped services, independent layers and failure recovery',
    () async {
      final presentation = FixturePresentation();
      final ocean = OceanExtension(
        state: state,
        createSampler: createSampler,
        createPresentation: (_, _) => presentation,
      );
      final host = GeospatialPlugin(extensions: [ocean]);
      await expectLater(engine([host]), throwsStateError);
      await expectLater(engine([ocean]), throwsA(isA<SceneException>()));
      final scene = await engine(host.scenePlugins);
      final physical = sampler!;
      final query = OceanQuery(
        const Vec3(0, 0, 6356752.314245179),
        host.clock.instant,
      );
      final before = (await physical.sampleBatch([
        query,
      ], OceanQueryPolicy())).single;
      expect(before.available, isTrue);
      expect(host.registry.find(oceanSampler), same(physical));
      expect(host.registry.find(oceanSeaState), same(state));
      host.layers.setVisible(ocean.foamLayerId, false);
      await scene.render(elapsed: Duration.zero, width: 8, height: 8);
      expect(presentation.frames.last.$2.surface, isTrue);
      expect(presentation.frames.last.$2.foam, isFalse);
      host.layers.setVisible(ocean.surfaceLayerId, false);
      await scene.render(
        elapsed: const Duration(milliseconds: 10),
        width: 8,
        height: 8,
      );
      expect(presentation.frames.last.$2.underwater, isTrue);
      expect(host.clock.tick, 0);
      expect(host.layers.effectiveQueryable(ocean.surfaceLayerId), isTrue);
      final hidden = (await physical.sampleBatch([
        query,
      ], OceanQueryPolicy())).single;
      expect(hidden.height, before.height);
      presentation.fail = true;
      await expectLater(
        scene.render(
          elapsed: const Duration(milliseconds: 20),
          width: 8,
          height: 8,
        ),
        throwsA(anything),
      );
      expect(
        host.layers.layer(ocean.surfaceLayerId).status.data,
        GeoLayerDataState.failed,
      );
      presentation.fail = false;
      await scene.render(
        elapsed: const Duration(milliseconds: 30),
        width: 8,
        height: 8,
      );
      expect(
        host.layers.layer(ocean.surfaceLayerId).status.data,
        GeoLayerDataState.ready,
      );
      await scene.dispose();
      expect(presentation.closed, isTrue);
      expect(host.registry.find(oceanSampler), isNull);
      expect(host.layers.snapshot, isEmpty);
      expect(
        (await physical.sampleBatch([
          query,
        ], OceanQueryPolicy())).single.failure,
        OceanQueryFailure.closed,
      );
    },
  );
  test(
    'factory failure and cancellation close acquired samplers without publishing layers',
    () async {
      final failed = OceanExtension(
        state: state,
        createSampler: createSampler,
        createPresentation: (_, _) => throw StateError('factory'),
      );
      final host = GeospatialPlugin(extensions: [failed]);
      await expectLater(engine(host.scenePlugins), throwsA(anything));
      expect(host.registry.snapshot, isEmpty);
      expect(host.layers.snapshot, isEmpty);
      final entered = Completer<void>(), gate = Completer<void>();
      final presentation = FixturePresentation();
      final delayed = OceanExtension(
        state: state,
        createSampler: createSampler,
        createPresentation: (_, _) async {
          entered.complete();
          await gate.future;
          return presentation;
        },
      );
      final second = GeospatialPlugin(extensions: [delayed]);
      final lifetime = AttachmentScope();
      final attaching = engine(second.scenePlugins, lifetime: lifetime);
      final rejection = expectLater(attaching, throwsA(anything));
      await entered.future;
      lifetime.close();
      gate.complete();
      await rejection;
      await lifetime.whenClosed;
      expect(presentation.closed, isTrue);
      expect(second.layers.snapshot, isEmpty);
      expect(second.registry.snapshot, isEmpty);
    },
  );
  test(
    'ocean providers and simulation drivers cannot acquire duplicate ownership',
    () async {
      OceanExtension create(String id) => OceanExtension(
        id: id,
        state: state,
        createSampler: createSampler,
        createPresentation: (_, _) => FixturePresentation(),
      );
      final host = GeospatialPlugin(extensions: [create('a'), create('b')]);
      await expectLater(engine(host.scenePlugins), throwsStateError);
      final driver = host.clock.acquireDriver('application');
      expect(() => host.clock.acquireDriver('duplicate'), throwsStateError);
      final simulation = GeoSimulation(systems: []);
      final physics = simulation.acquireDriver('physics');
      expect(() => simulation.acquireDriver('ocean'), throwsStateError);
      driver.dispose();
      physics.dispose();
      await physics.whenClosed;
    },
  );
}
