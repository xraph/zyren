import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';
import 'streaming_test.dart' show source, settle, flush;
import 'feature_test.dart' show batchModel, featureMeshes;

SceneAdmission receipt(Tiles3DStreamer streamer, bool ready) => SceneAdmission(
  candidateReady: ready,
  publishedRevision: 1,
  uploadBacklogBytes: ready ? 0 : 100,
  stagedBytes: ready ? 0 : 100,
  presentedIdentities: [
    for (final group in streamer.visible.values)
      for (final mesh in featureMeshes(group)) (mesh.id, mesh.geometry.id),
  ],
);
PerspectiveCamera camera(double distance) => PerspectiveCamera(
  position: Vec3(0, -distance, 0),
  up: const Vec3(0, 0, 1),
  far: 1e9,
);
const viewport = ViewportMetrics(800, 600);

void main() {
  test(
    'candidate decoding and incomplete receipts retain displayed cover and credits',
    () async {
      final gate = Completer<void>();
      final resolver =
          MemoryResolver({
              '/parent': triangleModel(
                changes: {
                  'asset': {'version': '2.0', 'copyright': 'Parent'},
                },
              ),
              '/a': triangleModel(
                changes: {
                  'asset': {'version': '2.0', 'copyright': 'A'},
                },
              ),
              '/b': triangleModel(
                changes: {
                  'asset': {'version': '2.0', 'copyright': 'B'},
                },
              ),
            })
            ..beforeRead = (uri, _) async {
              if (uri.path == '/b') await gate.future;
            };
      final streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            uri: 'parent',
            error: 10,
            refine: 'REPLACE',
            children: [
              tile(uri: 'a'),
              tile(uri: 'b'),
            ],
          ),
        ),
        services: AssetServices(resolver: resolver),
        trackPublication: true,
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(10000), viewport, elapsed: Duration.zero);
      await settle(streamer);
      expect(streamer.displayed, isEmpty);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      final parent = streamer.displayed['0'];
      streamer.update(camera(50), viewport, elapsed: Duration.zero);
      await flush();
      expect(streamer.visible.keys, ['0']);
      gate.complete();
      await settle(streamer);
      expect(streamer.visible.keys.toSet(), {'0/0', '0/1'});
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, false));
      expect(streamer.displayed['0'], same(parent));
      expect(streamer.attributions, ['Parent']);
      for (final group in streamer.visible.values) {
        expect(
          featureMeshes(group).every((m) => m.fragmentCoverage.isFull),
          isTrue,
        );
      }
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      expect(streamer.displayed.keys.toSet(), {'0/0', '0/1'});
      expect(streamer.attributions, ['A', 'B']);
    },
  );

  test(
    'styles keep displayed features immutable and deferred picks retain metadata',
    () async {
      final streamer = Tiles3DStreamer(
        tileset: await source(tile(uri: 'model', refine: 'REPLACE')),
        services: AssetServices(
          resolver: MemoryResolver({
            '/model': batchModel(copyright: 'Source credits'),
          }),
        ),
        trackPublication: true,
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(50), viewport);
      await settle(streamer);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      final scene = Scene(), group = PublicationGroup();
      scene.add(group);
      void sync() {
        group.stage(streamer.visible.values);
        group.publish(streamer.displayed.values);
      }

      sync();
      final raycaster = Raycaster();
      final ray = Ray(const Vec3(-1, -3, 0), const Vec3(0, 1, 0));
      final frozen = raycaster.capture(scene, ray);
      final old = frozen.intersectFirst()!;
      expect(streamer.featureFor(old)!.properties['name'], 'North');
      expect(streamer.featureFor(old)!.attributions, ['Source credits']);
      final oldBytes = streamer.stats.residentBytes;
      streamer.setStyle(TileStyle3D((_) => TileFeatureStyle3D(show: false)));
      sync();
      expect(
        streamer.stats.residentBytes,
        oldBytes,
        reason: 'shared model resources count once across style instances',
      );
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, false));
      sync();
      expect(
        raycaster.capture(scene, ray).intersectFirst()!.object,
        same(old.object),
      );
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      sync();
      expect(raycaster.capture(scene, ray).intersectFirst(), isNull);
      expect(
        streamer.featureFor(frozen.intersectFirst()!)!.properties['name'],
        'North',
      );
      expect(streamer.featureFor(frozen.intersectFirst()!)!.attributions, [
        'Source credits',
      ]);
    },
  );

  test(
    'source replacement retains exact submitted generation until publication',
    () async {
      final streamer = Tiles3DStreamer(
        tileset: await source(tile(uri: 'old', refine: 'REPLACE')),
        services: AssetServices(
          resolver: MemoryResolver({
            '/old': triangleModel(),
            '/new': triangleModel(),
          }),
        ),
        trackPublication: true,
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(50), viewport);
      await settle(streamer);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      final old = streamer.displayed['0'];
      streamer.beginFrame();
      streamer.replaceTileset(
        await source(tile(uri: 'new', refine: 'REPLACE')),
      );
      streamer.update(camera(50), viewport);
      await settle(streamer);
      streamer.completeFrame(receipt(streamer, true));
      expect(
        streamer.displayed['0'],
        same(old),
        reason: 'receipt belongs to the old submitted frame',
      );
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      expect(streamer.displayed['0'], isNot(same(old)));
      expect(
        featureMeshes(old!).first.geometry.capture().positions,
        isNotEmpty,
      );
    },
  );

  test(
    'superseded staged assets stay counted until the next native receipt',
    () async {
      final services = AssetServices(
        resolver: MemoryResolver({
          for (final n in ['old', 'next', 'last']) '/$n': triangleModel(),
        }),
      );
      final streamer = Tiles3DStreamer(
        tileset: await source(tile(uri: 'old', refine: 'REPLACE')),
        services: services,
        trackPublication: true,
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(50), viewport);
      await settle(streamer);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      final one = streamer.stats.residentBytes;
      streamer.replaceTileset(
        await source(tile(uri: 'next', refine: 'REPLACE')),
      );
      streamer.update(camera(50), viewport);
      await settle(streamer);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, false));
      expect(streamer.stats.residentBytes, one * 2);
      streamer.replaceTileset(
        await source(tile(uri: 'last', refine: 'REPLACE')),
      );
      streamer.update(camera(50), viewport);
      await settle(streamer);
      expect(streamer.stats.residentBytes, one * 3);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      expect(streamer.stats.residentBytes, one);
    },
  );

  test(
    'near-capacity navigation publishes a complete coarse bridge first',
    () async {
      Map<String, Object?> side(String uri, double x) =>
          tile(uri: uri)
            ..['boundingVolume'] = {
              'sphere': [x, 0, 0, 1],
            };
      final root =
          tile(
              uri: 'root',
              refine: 'REPLACE',
              error: 100,
              children: [
                side('a', -50),
                side('b', -48),
                side('c', 50),
                side('d', 48),
              ],
            )
            ..['boundingVolume'] = {
              'sphere': [0, 0, 0, 100],
            };
      final streamer = Tiles3DStreamer(
        tileset: await source(root),
        services: AssetServices(
          resolver: MemoryResolver({
            for (final n in ['root', 'a', 'b', 'c', 'd'])
              '/$n': triangleModel(),
          }),
        ),
        trackPublication: true,
        budget: Tiles3DBudget(maxResidentBytes: 234, perTileResidentBytes: 96),
      );
      addTearDown(streamer.dispose);
      final view = OrthographicCamera(
        position: const Vec3(-50, -50, 0),
        target: const Vec3(-50, 0, 0),
        up: const Vec3(0, 0, 1),
        left: -10,
        right: 10,
        bottom: -10,
        top: 10,
      );
      streamer.update(view, viewport);
      await settle(streamer);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      expect(streamer.displayed.keys.toSet(), {'0/0', '0/1'});
      view.position = const Vec3(50, -50, 0);
      view.target = const Vec3(50, 0, 0);
      streamer.update(view, viewport);
      await settle(streamer);
      expect(streamer.visible.keys, ['0']);
      expect(streamer.stats.residentBytes, 234);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      expect(streamer.displayed.keys, ['0']);
      expect(streamer.visible.keys.toSet(), {'0/2', '0/3'});
      expect(streamer.stats.residentBytes, 234);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      expect(streamer.displayed.keys.toSet(), {'0/2', '0/3'});
    },
  );

  test(
    'overlap refusal retains a complete parent without repeated new candidates',
    () async {
      final streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            uri: 'parent',
            refine: 'REPLACE',
            error: 10,
            children: [
              tile(uri: 'a'),
              tile(uri: 'b'),
            ],
          ),
        ),
        services: AssetServices(
          resolver: MemoryResolver({
            for (final n in ['parent', 'a', 'b']) '/$n': triangleModel(),
          }),
        ),
        trackPublication: true,
        budget: Tiles3DBudget(maxResidentBytes: 192, perTileResidentBytes: 96),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(10000), viewport);
      await settle(streamer);
      streamer.beginFrame();
      streamer.completeFrame(receipt(streamer, true));
      streamer.update(camera(50), viewport);
      await settle(streamer);
      expect(streamer.visible.keys, ['0']);
      expect(streamer.stats.budgetLimited, isTrue);
      expect(streamer.stats.residentBytes, lessThanOrEqualTo(192));
    },
  );
}
