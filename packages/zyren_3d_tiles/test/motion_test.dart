import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';
import 'publication_test.dart' show receipt;
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
  for (final limit in [2048, 3072]) {
    test(
      'stable byte lanes preserve sequential visible requests at $limit',
      () async {
        final gate = Completer<void>();
        final resolver =
            MemoryResolver({
                for (final n in ['a', 'b', 'd', 'e']) '/$n': triangleModel(),
              })
              ..beforeRead = (uri, context) async {
                if (uri.path == '/b') await gate.future;
              };
        final root =
            tile(
                refine: 'REPLACE',
                children: [at('a', 0), at('b', 12), at('d', -24), at('e', -48)],
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
            maxDecodedBytes: limit,
            perTileResidentBytes: 1024,
            maxResidentBytes: limit,
          ),
        );
        addTearDown(() async {
          if (!gate.isCompleted) gate.complete();
          await streamer.dispose();
        });
        final view = OrthographicCamera(
          position: const Vec3(0, -50, 0),
          up: const Vec3(0, 0, 1),
          left: -10,
          right: 10,
          top: 10,
          bottom: -10,
        );
        void move(double x, int ms) {
          view.position = Vec3(x, -50, 0);
          view.target = Vec3(x, 0, 0);
          streamer.update(
            view,
            const ViewportMetrics(100, 100),
            elapsed: Duration(milliseconds: ms),
          );
        }

        Future<void> visible(String id) async {
          for (var i = 0; i < 200 && !streamer.visible.containsKey(id); i++) {
            expect(
              streamer.stats.reservedBytes + streamer.stats.cachedBytes,
              lessThanOrEqualTo(limit),
            );
            expect(streamer.stats.residentBytes, lessThanOrEqualTo(limit));
            await Future<void>.delayed(const Duration(milliseconds: 2));
          }
          expect(streamer.visible.keys, [id]);
        }

        move(0, 0);
        await visible('0/0');
        expect(resolver.reads.contains('/b'), limit == 3072);
        move(-24, 100);
        await visible('0/2');
        move(-48, 200);
        await visible('0/3');
        expect(gate.isCompleted, isFalse);
        gate.complete();
        await settle(streamer);
        expect(streamer.stats.reservedBytes, 0);
      },
    );
  }
  for (final constrained in ['both', 'decoded', 'resident']) {
    test(
      'cached promotion reclaims inactive visible bytes: $constrained',
      () async {
        final view = OrthographicCamera(
          position: const Vec3(0, -50, 0),
          up: const Vec3(0, 0, 1),
          left: -10,
          right: 10,
          top: 10,
          bottom: -10,
        );
        final measure = Tiles3DStreamer(
          tileset: await source(tile(uri: 'm', refine: 'REPLACE')),
          services: AssetServices(
            resolver: MemoryResolver({'/m': triangleModel()}),
          ),
        );
        measure.update(view, const ViewportMetrics(100, 100));
        await settle(measure);
        final decoded = measure.stats.cachedBytes;
        final resident = measure.stats.residentBytes;
        await measure.dispose();
        final decodedCap = decoded * (constrained == 'resident' ? 4 : 3);
        final residentCap = resident * (constrained == 'decoded' ? 4 : 3);
        final resolver = MemoryResolver({
          for (final n in ['a', 'd', 'b']) '/$n': triangleModel(),
        });
        final root =
            tile(
                refine: 'REPLACE',
                children: [at('a', 0), at('d', 36), at('b', 48)],
              )
              ..['boundingVolume'] = {
                'sphere': [0, 0, 0, 100],
              };
        final streamer = Tiles3DStreamer(
          tileset: await source(root),
          services: AssetServices(resolver: resolver),
          trackPublication: true,
          clock: () => DateTime.utc(2026),
          motionPolicy: const Tiles3DMotionPolicy(),
          budget: Tiles3DBudget(
            maxRequests: 2,
            maxPrefetchRequests: 1,
            maxPrefetchTiles: 1,
            maxPrefetchBytes: decoded,
            perTileDecodedBytes: decoded,
            maxDecodedBytes: decodedCap,
            perTileResidentBytes: resident,
            maxResidentBytes: residentCap,
          ),
        );
        addTearDown(streamer.dispose);
        void bounded() {
          expect(
            streamer.stats.cachedBytes + streamer.stats.reservedBytes,
            lessThanOrEqualTo(decodedCap),
          );
          expect(
            streamer.stats.residentBytes,
            lessThanOrEqualTo(residentCap - resident),
          );
          expect(streamer.stats.prefetchBytes, lessThanOrEqualTo(decoded));
        }

        void move(double x, int ms) {
          view.position = Vec3(x, -50, 0);
          view.target = Vec3(x, 0, 0);
          streamer.update(
            view,
            const ViewportMetrics(100, 100),
            elapsed: Duration(milliseconds: ms),
          );
          bounded();
        }

        void accept() {
          streamer.beginFrame();
          streamer.completeFrame(receipt(streamer, true));
          bounded();
        }

        move(0, 0);
        await settle(streamer);
        accept();
        expect(streamer.displayed.keys, ['0/0']);
        move(36, 100);
        await settle(streamer);
        accept();
        expect(streamer.displayed.keys, ['0/1']);
        expect(streamer.selected.containsKey('0/0'), isFalse);
        expect(streamer.visible.keys, ['0/1']);
        expect(
          streamer.stats.cachedBytes,
          decoded * 3,
          reason:
              'A stays fresh but is no longer selected or pinned after D receipt',
        );
        expect(streamer.stats.prefetchedTiles, 1);
        expect(streamer.stats.reservedBytes, 0);
        expect(resolver.reads, ['/a', '/d', '/b']);
        move(48, 200);
        for (var i = 0; i < 4; i++) {
          accept();
          move(48, 220 + i * 20);
          await settle(streamer);
        }
        expect(streamer.visible.keys, ['0/2']);
        expect(streamer.displayed.keys, ['0/2']);
        expect(
          streamer.stats.cachedBytes,
          decoded * 2,
          reason:
              'Promotion reclaims A and retains D/B overlap without refetch',
        );
        expect(streamer.stats.reservedBytes, 0);
        expect(resolver.reads, ['/a', '/d', '/b']);
      },
    );
  }
  test('prefetch promotion respects pinned visible byte quota', () async {
    final measure = Tiles3DStreamer(
      tileset: await source(tile(uri: 'm', refine: 'REPLACE')),
      services: AssetServices(
        resolver: MemoryResolver({'/m': triangleModel()}),
      ),
    );
    final view = OrthographicCamera(
      position: const Vec3(0, -50, 0),
      up: const Vec3(0, 0, 1),
      left: -10,
      right: 10,
      top: 10,
      bottom: -10,
    );
    measure.update(view, const ViewportMetrics(100, 100));
    await settle(measure);
    final decoded = measure.stats.cachedBytes,
        resident = measure.stats.residentBytes;
    await measure.dispose();
    final root =
        tile(
            refine: 'REPLACE',
            children: [at('a', -4), at('d', 4), at('b', 12)],
          )
          ..['boundingVolume'] = {
            'sphere': [0, 0, 0, 100],
          };
    final resolver = MemoryResolver({
      for (final n in ['a', 'd', 'b']) '/$n': triangleModel(),
    });
    final streamer = Tiles3DStreamer(
      tileset: await source(root),
      services: AssetServices(resolver: resolver),
      trackPublication: true,
      motionPolicy: const Tiles3DMotionPolicy(),
      budget: Tiles3DBudget(
        maxRequests: 3,
        maxPrefetchRequests: 1,
        maxPrefetchTiles: 1,
        maxPrefetchBytes: decoded,
        perTileDecodedBytes: decoded,
        maxDecodedBytes: decoded * 3,
        perTileResidentBytes: resident,
        maxResidentBytes: resident * 3,
      ),
    );
    addTearDown(streamer.dispose);
    void update() => streamer.update(view, const ViewportMetrics(100, 100));
    update();
    await settle(streamer);
    expect(streamer.visible.keys.toSet(), {'0/0', '0/1'});
    expect(streamer.stats.prefetchedTiles, 1);
    streamer.beginFrame();
    streamer.completeFrame(receipt(streamer, true));
    view.position = const Vec3(12, -50, 0);
    view.target = const Vec3(12, 0, 0);
    update();
    await settle(streamer);
    expect(streamer.visible.containsKey('0/2'), isFalse);
    expect(streamer.displayed.keys.toSet(), {'0/0', '0/1'});
    expect(streamer.stats.budgetLimited, isTrue);
    expect(
      streamer.stats.cachedBytes + streamer.stats.reservedBytes,
      lessThanOrEqualTo(decoded * 3),
    );
    expect(streamer.stats.residentBytes, lessThanOrEqualTo(resident * 3));
  });
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
