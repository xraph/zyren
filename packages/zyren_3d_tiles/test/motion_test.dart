import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';
import 'streaming_test.dart' show source, settle, HeaderResolver;

Map<String, Object?> at(String uri, double x) =>
    tile(uri: uri)
      ..['boundingVolume'] = {
        'sphere': [x, 0, 0, 1],
      };
void main() {
  test('prediction keeps updates alive beyond SSE settlement', () async {
    final streamer = Tiles3DStreamer(
      tileset: await source(tile(uri: 'a', refine: 'REPLACE')),
      services: AssetServices(
        resolver: MemoryResolver({'/a': triangleModel()}),
      ),
      motionPolicy: const Tiles3DMotionPolicy(
        prediction: Duration(seconds: 1),
        settle: Duration(milliseconds: 50),
      ),
    );
    addTearDown(streamer.dispose);
    final view = OrthographicCamera(
      position: const Vec3(0, -50, 0),
      up: const Vec3(0, 0, 1),
    );
    void update(int ms) => streamer.update(
      view,
      const ViewportMetrics(100, 100),
      elapsed: Duration(milliseconds: ms),
    );
    update(0);
    view.position = const Vec3(1, -50, 0);
    view.target = const Vec3(1, 0, 0);
    update(40);
    update(90);
    expect(streamer.effectiveScreenError, 8);
    expect(streamer.needsUpdate, isTrue);
    update(1039);
    expect(streamer.needsUpdate, isTrue);
    update(1040);
    expect(streamer.needsUpdate, isFalse);
  });
  test(
    'adjacent and predicted work is bounded, visible-first and expires after reversal',
    () async {
      final resolver = MemoryResolver({
        for (final n in ['a', 'b', 'c', 'd']) '/$n': triangleModel(),
      });
      final root =
          tile(
              refine: 'REPLACE',
              children: [at('a', 0), at('b', 12), at('c', 24), at('d', -24)],
            )
            ..['boundingVolume'] = {
              'sphere': [0, 0, 0, 100],
            };
      final streamer = Tiles3DStreamer(
        tileset: await source(root),
        services: AssetServices(resolver: resolver),
        motionPolicy: const Tiles3DMotionPolicy(),
        budget: Tiles3DBudget(
          maxRequests: 2,
          maxPrefetchRequests: 1,
          maxPrefetchTiles: 1,
          maxPrefetchBytes: 1024,
          perTileDecodedBytes: 1024,
        ),
      );
      addTearDown(streamer.dispose);
      final camera = OrthographicCamera(
        position: const Vec3(0, -50, 0),
        up: const Vec3(0, 0, 1),
        left: -10,
        right: 10,
        top: 10,
        bottom: -10,
      );
      void move(double x, int ms) {
        camera.position = Vec3(x, -50, 0);
        camera.target = Vec3(x, 0, 0);
        streamer.update(
          camera,
          const ViewportMetrics(100, 100),
          elapsed: Duration(milliseconds: ms),
        );
      }

      move(0, 0);
      await settle(streamer);
      expect(resolver.reads.take(2), ['/a', '/b']);
      expect(streamer.visible.keys, ['0/0']);
      expect(streamer.stats.prefetchedTiles, 1);
      move(5, 100);
      await settle(streamer);
      expect(resolver.reads, contains('/c'));
      expect(streamer.stats.prefetchedTiles, lessThanOrEqualTo(1));
      expect(streamer.stats.prefetchBytes, lessThanOrEqualTo(1024));
      expect(streamer.effectiveScreenError, greaterThan(8));
      move(0, 150);
      await settle(streamer);
      move(0, 500);
      await settle(streamer);
      expect(streamer.effectiveScreenError, 8);
      expect(streamer.needsUpdate, isFalse);
      final count = resolver.reads.length;
      move(0, 600);
      await settle(streamer);
      expect(resolver.reads.length, count);
      camera.target = const Vec3(0, -100, 0);
      streamer.update(
        camera,
        const ViewportMetrics(100, 100),
        elapsed: const Duration(milliseconds: 700),
      );
      await settle(streamer);
      expect(streamer.visible, isEmpty);
      expect(streamer.stats.prefetchedTiles, 0);
    },
  );
  test(
    'expired and no-store prefetch is fetched again before visible promotion',
    () async {
      for (final headers in [
        {'cache-control': 'max-age=1'},
        {'cache-control': 'no-store'},
      ]) {
        var now = DateTime.utc(2026);
        final resolver = HeaderResolver({
          '/a': triangleModel(),
          '/b': triangleModel(),
        }, headers);
        final root =
            tile(refine: 'REPLACE', children: [at('a', 0), at('b', 12)])
              ..['boundingVolume'] = {
                'sphere': [0, 0, 0, 100],
              };
        final streamer = Tiles3DStreamer(
          tileset: await source(root),
          services: AssetServices(resolver: resolver),
          motionPolicy: const Tiles3DMotionPolicy(),
          clock: () => now,
          budget: Tiles3DBudget(
            maxRequests: 2,
            maxPrefetchRequests: 1,
            maxPrefetchTiles: 1,
            maxPrefetchBytes: 1024,
            perTileDecodedBytes: 1024,
          ),
        );
        addTearDown(streamer.dispose);
        final view = OrthographicCamera(
          position: const Vec3(0, -50, 0),
          up: const Vec3(0, 0, 1),
          left: -10,
          right: 10,
          top: 10,
          bottom: -10,
        );
        streamer.update(
          view,
          const ViewportMetrics(100, 100),
          elapsed: Duration.zero,
        );
        await settle(streamer);
        expect(resolver.reads.where((p) => p == '/b').length, 1);
        now = now.add(const Duration(seconds: 2));
        view.position = const Vec3(12, -50, 0);
        view.target = const Vec3(12, 0, 0);
        streamer.update(
          view,
          const ViewportMetrics(100, 100),
          elapsed: const Duration(seconds: 2),
        );
        await settle(streamer);
        expect(resolver.reads.where((p) => p == '/b').length, 2);
        expect(streamer.visible.keys, ['0/1']);
      }
    },
  );
  test(
    'cancelled prefetch keeps its physical reservation while visible work proceeds',
    () async {
      final gate = Completer<void>(), started = Completer<void>();
      final resolver =
          MemoryResolver({
              for (final n in ['a', 'b', 'd']) '/$n': triangleModel(),
            })
            ..beforeRead = (uri, context) async {
              if (uri.path == '/b') {
                started.complete();
                await gate.future;
              }
            };
      final root =
          tile(
              refine: 'REPLACE',
              children: [at('a', 0), at('b', 12), at('d', -24)],
            )
            ..['boundingVolume'] = {
              'sphere': [0, 0, 0, 100],
            };
      final streamer = Tiles3DStreamer(
        tileset: await source(root),
        services: AssetServices(resolver: resolver),
        motionPolicy: const Tiles3DMotionPolicy(),
        budget: Tiles3DBudget(
          maxRequests: 2,
          maxPrefetchRequests: 1,
          maxPrefetchTiles: 1,
          maxPrefetchBytes: 1024,
          perTileDecodedBytes: 1024,
        ),
      );
      addTearDown(streamer.dispose);
      final view = OrthographicCamera(
        position: const Vec3(0, -50, 0),
        up: const Vec3(0, 0, 1),
        left: -10,
        right: 10,
        top: 10,
        bottom: -10,
      );
      streamer.update(
        view,
        const ViewportMetrics(100, 100),
        elapsed: Duration.zero,
      );
      await started.future;
      view.position = const Vec3(-24, -50, 0);
      view.target = const Vec3(-24, 0, 0);
      streamer.update(
        view,
        const ViewportMetrics(100, 100),
        elapsed: const Duration(milliseconds: 100),
      );
      for (var i = 0; i < 100 && !resolver.reads.contains('/d'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(resolver.reads, contains('/d'));
      expect(streamer.stats.reservedBytes, greaterThanOrEqualTo(1024));
      gate.complete();
      await settle(streamer);
      expect(streamer.stats.prefetchedTiles, 0);
      expect(streamer.stats.reservedBytes, 0);
      expect(streamer.visible.keys, ['0/2']);
    },
  );
  test('optional visibility policy excludes complete hidden bounds', () async {
    final resolver = MemoryResolver({
      '/a': triangleModel(),
      '/b': triangleModel(),
    });
    final streamer = Tiles3DStreamer(
      tileset: await source(
        tile(refine: 'REPLACE', children: [at('a', -1), at('b', 1)]),
      ),
      services: AssetServices(resolver: resolver),
      visibilityPolicy: (bounds, camera) => bounds.center.x <= 0,
    );
    addTearDown(streamer.dispose);
    streamer.update(
      PerspectiveCamera(
        position: const Vec3(0, -50, 0),
        up: const Vec3(0, 0, 1),
      ),
      const ViewportMetrics(800, 600),
    );
    await settle(streamer);
    expect(resolver.reads, ['/a']);
  });
}
