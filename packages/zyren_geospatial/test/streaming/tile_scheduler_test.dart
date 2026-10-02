import 'dart:async';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

const root = TileCoordinate(0, 0, 0);
final children = root.traverseChildren(1).toList();
const viewport = ViewportMetrics(800, 600);
PerspectiveCamera camera(double distance) => PerspectiveCamera(
  position: Vec3(0, 0, distance),
  fieldOfView: math.pi / 2,
  near: .1,
  far: 1e6,
);
Future<void> flush() => Future<void>.delayed(Duration.zero);

class Content implements TileContent {
  @override
  final int decodedBytes;
  @override
  final int residentBytes;
  Content([this.decodedBytes = 100, this.residentBytes = 100]);
}

class Pending {
  final TileCoordinate tile;
  final TileLoadContext context;
  final result = Completer<Content>();
  Pending(this.tile, this.context);
}

class Source implements TileSource<Content> {
  @override
  final String identity;
  final requests = <Pending>[];
  Source([this.identity = 'fixture:v1']);
  @override
  Iterable<TileCoordinate> get roots => [root];
  @override
  TileMetadata describe(TileCoordinate tile) => TileMetadata(
    coordinate: tile,
    center: Vec3.zero,
    radius: 10,
    geometricError: tile.z == 0 ? 10 : 0,
    decodedBytes: 100,
    residentBytes: 100,
    children: tile.z == 0 ? children : const [],
  );
  @override
  Future<Content> load(TileCoordinate tile, TileLoadContext context) {
    final request = Pending(tile, context);
    requests.add(request);
    return request.result.future;
  }

  Future<void> finish(
    TileCoordinate tile, {
    Object? error,
    Content? content,
  }) async {
    final request = requests.lastWhere((r) => r.tile == tile);
    if (error != null) {
      request.result.completeError(error);
    } else {
      request.result.complete(content ?? Content());
    }
    await flush();
  }
}

void main() {
  test('perspective, zoom and orthographic error use viewport pixels', () {
    final metadata = Source().describe(root);
    expect(metadata.screenError(camera(110), viewport), closeTo(30, 1e-10));
    expect(
      metadata.screenError(camera(110)..zoom = 2, viewport),
      closeTo(60, 1e-10),
    );
    final ortho = OrthographicCamera(top: 100, bottom: -100, zoom: 2);
    expect(metadata.screenError(ortho, viewport), 60);
  });

  test('parents remain visible until every selected child is ready', () async {
    final source = Source();
    final scheduler = TileScheduler(
      source: source,
      budget: TileBudget(maxRequests: 2),
    );
    addTearDown(scheduler.dispose);
    scheduler.update(camera(100), viewport);
    expect(source.requests.map((r) => r.tile), [root, children[0]]);
    await source.finish(root);
    expect(scheduler.visible.keys, [root]);
    for (final child in children.take(3)) {
      await source.finish(child);
      expect(scheduler.visible.keys, [root]);
    }
    await source.finish(children.last);
    expect(scheduler.visible.keys, children);
    expect(scheduler.stats.activeRequests, 0);
    expect(scheduler.stats.cachedBytes, 500);
    expect(scheduler.stats.residentBytes, 400);
    scheduler.update(camera(10000), viewport);
    expect(scheduler.visible.keys, [root]);
    expect(scheduler.stats.residentBytes, 100);
  });

  test('cancelled work keeps its slot and late results never attach', () async {
    final source = Source();
    final scheduler = TileScheduler(
      source: source,
      budget: TileBudget(maxRequests: 1),
    );
    addTearDown(scheduler.dispose);
    scheduler.update(camera(100), viewport);
    await source.finish(root);
    final child = source.requests.last;
    scheduler.update(camera(10000), viewport);
    expect(child.context.cancellation.isCancelled, isTrue);
    expect(scheduler.stats.activeRequests, 1);
    scheduler.update(camera(100), viewport);
    expect(source.requests.length, 2);
    await source.finish(child.tile);
    expect(scheduler.stats.cachedBytes, 100);
    expect(source.requests.length, 3);
    expect(scheduler.visible.keys, [root]);
  });

  test(
    'source replacement rejects old results even with the same identity',
    () async {
      final old = Source(), next = Source();
      final scheduler = TileScheduler(
        source: old,
        budget: TileBudget(maxRequests: 1),
      );
      addTearDown(scheduler.dispose);
      scheduler.update(camera(10000), viewport);
      scheduler.replaceSource(next);
      scheduler.update(camera(10000), viewport);
      expect(old.requests.single.context.cancellation.isCancelled, isTrue);
      expect(next.requests, isEmpty);
      await old.finish(root);
      expect(scheduler.visible, isEmpty);
      expect(next.requests.length, 1);
      await next.finish(root);
      expect(scheduler.visible.keys, [root]);
    },
  );

  test(
    'explicit retries are capped and failures preserve parent coverage',
    () async {
      final source = Source();
      final scheduler = TileScheduler(
        source: source,
        budget: TileBudget(maxRequests: 5, maxAttempts: 2),
      );
      addTearDown(scheduler.dispose);
      scheduler.update(camera(100), viewport);
      await source.finish(root);
      for (final child in children.skip(1)) {
        await source.finish(child);
      }
      await source.finish(children.first, error: StateError('offline'));
      expect(scheduler.visible.keys, [root]);
      expect(scheduler.failures.single.sourceIdentity, source.identity);
      expect(scheduler.failures.single.coordinate, children.first);
      for (var i = 0; i < 10; i++) {
        scheduler.update(camera(100), viewport);
      }
      expect(source.requests.length, 5);
      scheduler.retryFailed();
      expect(source.requests.length, 6);
      await source.finish(children.first, error: StateError('still offline'));
      scheduler.retryFailed();
      expect(source.requests.length, 6);
      expect(scheduler.visible.keys, [root]);
    },
  );

  test(
    'byte budget coarsens before requesting an incomplete sibling group',
    () async {
      final source = Source();
      final scheduler = TileScheduler(
        source: source,
        budget: TileBudget(maxDecodedBytes: 499, maxResidentBytes: 500),
      );
      addTearDown(scheduler.dispose);
      scheduler.update(camera(100), viewport);
      await source.finish(root);
      expect(source.requests.length, 1);
      expect(scheduler.visible.keys, [root]);
      expect(scheduler.stats.budgetLimited, isTrue);
    },
  );

  test('oversized payloads fail admission without retaining bytes', () async {
    final source = Source();
    final scheduler = TileScheduler(source: source);
    addTearDown(scheduler.dispose);
    scheduler.update(camera(10000), viewport);
    await source.finish(root, content: Content(101, 100));
    expect(scheduler.visible, isEmpty);
    expect(scheduler.stats.cachedBytes, 0);
    expect(scheduler.failures.single.error, isA<StateError>());
  });

  test(
    'frustum exit cancels requests; hysteresis avoids threshold churn',
    () async {
      final source = Source();
      final scheduler = TileScheduler(source: source, maximumScreenError: 10);
      addTearDown(scheduler.dispose);
      scheduler.update(camera(290), viewport); // error 10.71, refine
      expect(scheduler.selected.length, 5);
      scheduler.update(camera(340), viewport); // error 9.09, retain children
      expect(scheduler.selected.length, 5);
      scheduler.update(camera(410), viewport); // error 7.5, coarsen
      expect(scheduler.selected, {root});
      final away = camera(100)..target = const Vec3(0, 0, 200);
      scheduler.update(away, viewport);
      expect(scheduler.selected, isEmpty);
      expect(
        source.requests.every((r) => r.context.cancellation.isCancelled),
        isTrue,
      );
    },
  );

  test('dispose cancels and ignores all late completions', () async {
    final source = Source();
    var changes = 0;
    final scheduler = TileScheduler(source: source, onChanged: () => changes++);
    scheduler.update(camera(10000), viewport);
    scheduler.dispose();
    final previous = changes;
    await source.finish(root);
    expect(changes, previous);
    expect(scheduler.visible, isEmpty);
    expect(scheduler.stats.cachedBytes, 0);
    expect(() => scheduler.update(camera(100), viewport), throwsStateError);
  });

  test(
    'LRU evicts unused tiles while active coverage remains pinned',
    () async {
      final source = Regions();
      final scheduler = TileScheduler(
        source: source,
        budget: TileBudget(maxDecodedBytes: 200),
      );
      addTearDown(scheduler.dispose);
      Future<void> visit(int x, {bool cached = false}) async {
        final point = Vec3(x * 1000.0, 0, 0);
        final before = source.requests.length;
        scheduler.update(
          camera(100)
            ..position = point + const Vec3(0, 0, 100)
            ..target = point,
          viewport,
        );
        if (cached) {
          expect(source.requests.length, before);
        } else {
          await source.finish(TileCoordinate(x, 0, 0));
        }
        expect(scheduler.visible.keys, [TileCoordinate(x, 0, 0)]);
        expect(
          scheduler.stats.cachedBytes + scheduler.stats.reservedBytes,
          lessThanOrEqualTo(200),
        );
      }

      await visit(0);
      await visit(1);
      await visit(0, cached: true);
      await visit(2);
      await visit(0, cached: true);
      await visit(1);
      expect(source.requests.map((r) => r.tile.x), [0, 1, 2, 1]);
    },
  );

  test(
    'reserved and cached bytes stay bounded throughout concurrent completion',
    () async {
      final source = Source();
      final scheduler = TileScheduler(
        source: source,
        budget: TileBudget(maxRequests: 5, maxDecodedBytes: 500),
      );
      addTearDown(scheduler.dispose);
      scheduler.update(camera(100), viewport);
      expect(scheduler.stats.reservedBytes, 500);
      for (final tile in [root, ...children]) {
        await source.finish(tile);
        expect(
          scheduler.stats.cachedBytes + scheduler.stats.reservedBytes,
          500,
        );
      }
    },
  );

  test(
    'a successful retry replaces fallback without missing coverage',
    () async {
      final source = Source();
      final scheduler = TileScheduler(
        source: source,
        budget: TileBudget(maxRequests: 5),
      );
      addTearDown(scheduler.dispose);
      scheduler.update(camera(100), viewport);
      await source.finish(root);
      for (final child in children.skip(1)) {
        await source.finish(child);
      }
      await source.finish(children.first, error: StateError('offline'));
      scheduler.retryFailed();
      expect(scheduler.visible.keys, [root]);
      await source.finish(children.first);
      expect(scheduler.visible.keys, children);
      expect(scheduler.failures, isEmpty);
    },
  );
}

class Regions extends Source {
  @override
  Iterable<TileCoordinate> get roots => [
    for (var x = 0; x < 3; x++) TileCoordinate(x, 0, 0),
  ];
  @override
  TileMetadata describe(TileCoordinate tile) => TileMetadata(
    coordinate: tile,
    center: Vec3(tile.x * 1000.0, 0, 0),
    radius: 10,
    geometricError: 0,
    decodedBytes: 100,
    residentBytes: 100,
  );
}
