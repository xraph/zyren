import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';

Future<Tileset3D> source(Map<String, Object?> root) async {
  final scope = AssetScope(
    services: AssetServices(
      resolver: MemoryResolver({'/tileset': tilesetBytes(root)}),
    ),
  );
  try {
    return await scope
        .load(Tiles3D.tileset(Uri.parse('https://tiles.test/tileset')))
        .result;
  } finally {
    await scope.close();
  }
}

Future<void> flush() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

Future<void> settle(Tiles3DStreamer streamer) async {
  for (var i = 0; i < 200; i++) {
    if (streamer.stats.activeRequests == 0) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Tile requests did not settle.');
}

void main() {
  test(
    'small sibling groups load incrementally within physical reservations',
    () async {
      final resolver = MemoryResolver({
        for (final name in ['parent', 'a', 'b', 'c', 'd'])
          '/$name': triangleModel(),
      });
      var inFlight = 0, peak = 0;
      resolver.beforeRead = (_, _) async {
        inFlight++;
        if (inFlight > peak) peak = inFlight;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        inFlight--;
      };
      final streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            uri: 'parent',
            refine: 'REPLACE',
            error: 100,
            children: [
              for (final name in ['a', 'b', 'c', 'd']) tile(uri: name),
            ],
          ),
        ),
        services: AssetServices(resolver: resolver),
        budget: Tiles3DBudget(
          maxRequests: 4,
          maxDecodedBytes: 65536,
          perTileDecodedBytes: 8192,
          maxResidentBytes: 4096,
          perTileResidentBytes: 2048,
        ),
      );
      addTearDown(streamer.dispose);
      final view = PerspectiveCamera(
        position: const Vec3(0, -50, 0),
        up: const Vec3(0, 0, 1),
      );
      streamer.update(view, const ViewportMetrics(800, 600));
      await settle(streamer);
      streamer.update(view, const ViewportMetrics(800, 600));
      await settle(streamer);
      expect(streamer.visible.keys.toSet(), {'0/0', '0/1', '0/2', '0/3'});
      expect(resolver.reads.toSet(), {'/parent', '/a', '/b', '/c', '/d'});
      expect(peak, 2, reason: 'GPU reservations must limit physical reads.');
      expect(
        streamer.stats.cachedBytes + streamer.stats.reservedBytes,
        lessThanOrEqualTo(65536),
      );
      expect(streamer.stats.residentBytes, lessThanOrEqualTo(4096));
    },
  );

  test(
    'visible attribution follows parent fallback and excludes cached invisible tiles',
    () async {
      final resolver = MemoryResolver({
        '/parent': triangleModel(
          changes: {
            'asset': {'version': '2.0', 'copyright': 'Parent; Shared'},
          },
        ),
        '/one': triangleModel(
          changes: {
            'asset': {'version': '2.0', 'copyright': 'Zeta; Shared'},
          },
        ),
      });
      final s = Tiles3DStreamer(
        tileset: await source(
          tile(
            refine: 'REPLACE',
            uri: 'parent',
            error: 10,
            children: [
              tile(uri: 'one'),
              tile(uri: 'two'),
            ],
          ),
        ),
        services: AssetServices(resolver: resolver),
      );
      addTearDown(s.dispose);
      final camera = PerspectiveCamera(
        position: const Vec3(0, -50, 0),
        up: const Vec3(0, 0, 1),
      );
      s.update(camera, const ViewportMetrics(800, 600));
      await settle(s);
      expect(s.attributions, ['Parent', 'Shared']);
      resolver.files['/two'] = triangleModel(
        changes: {
          'asset': {'version': '2.0', 'copyright': 'Alpha;Shared'},
        },
      );
      s.retryFailed();
      await settle(s);
      expect(s.attributions, ['Alpha', 'Shared', 'Zeta']);
      expect(() => s.attributions.clear(), throwsUnsupportedError);
      camera.position = const Vec3(0, -1000000, 0);
      s.update(camera, const ViewportMetrics(800, 600));
      expect(s.attributions, isEmpty);
    },
  );

  test(
    'HTTP freshness limits inactive cache reuse without refetching every frame',
    () async {
      for (final (headers, keepsFresh) in [
        ({'cache-control': 'private, max-age=10', 'age': '3'}, true),
        (
          {
            'cache-control': 'max-age="10"',
            'date': 'Sun, 27 Sep 2026 23:59:57 GMT',
          },
          true,
        ),
        ({'expires': 'Mon, 28 Sep 2026 00:00:07 GMT'}, true),
        ({'cache-control': 'no-store'}, false),
        ({'cache-control': 'no-cache'}, false),
        ({'cache-control': 'max-age=9999999999999999999999'}, false),
        ({'cache-control': 'max-age=10, max-age=30'}, false),
      ]) {
        var now = DateTime.utc(2026, 9, 28);
        final resolver = HeaderResolver({
          '/left': triangleModel(),
          '/right': triangleModel(),
        }, headers);
        Map<String, Object?> side(String uri, double x) =>
            tile(uri: uri)
              ..['boundingVolume'] = {
                'sphere': [x, 0, 0, 3],
              };
        final root =
            tile(
                refine: 'REPLACE',
                children: [side('left', -50), side('right', 50)],
              )
              ..['boundingVolume'] = {
                'sphere': [0, 0, 0, 100],
              };
        final s = Tiles3DStreamer(
          tileset: await source(root),
          services: AssetServices(resolver: resolver),
          clock: () => now,
        );
        addTearDown(s.dispose);
        final camera = OrthographicCamera(
          left: -5,
          right: 5,
          bottom: -5,
          top: 5,
          position: const Vec3(-50, -50, 0),
          target: const Vec3(-50, 0, 0),
          up: const Vec3(0, 0, 1),
        );
        void look(double x) {
          camera.position = Vec3(x, -50, 0);
          camera.target = Vec3(x, 0, 0);
          s.update(camera, const ViewportMetrics(800, 600));
        }

        look(-50);
        await settle(s);
        look(-50);
        await settle(s);
        expect(resolver.reads.where((p) => p == '/left'), hasLength(1));
        look(50);
        await settle(s);
        look(-50);
        await settle(s);
        expect(
          resolver.reads.where((p) => p == '/left'),
          hasLength(keepsFresh ? 1 : 2),
        );
        look(50);
        await settle(s);
        now = now.add(const Duration(seconds: 8));
        look(-50);
        await settle(s);
        expect(
          resolver.reads.where((p) => p == '/left'),
          hasLength(keepsFresh ? 2 : 3),
        );
        expect(s.failures, isEmpty);
      }
    },
  );

  test(
    'expired external metadata also retires payloads whose identity it defined',
    () async {
      final resolver = MetadataHeaders({
        '/nested': tilesetBytes(tile(refine: 'REPLACE', uri: 'old')),
        '/old': triangleModel(
          changes: {
            'asset': {'version': '2.0', 'copyright': 'Old'},
          },
        ),
        '/new': triangleModel(
          changes: {
            'asset': {'version': '2.0', 'copyright': 'New'},
          },
        ),
      });
      final s = Tiles3DStreamer(
        tileset: await source(tile(refine: 'REPLACE', uri: 'nested')),
        services: AssetServices(resolver: resolver),
      );
      addTearDown(s.dispose);
      final camera = PerspectiveCamera(
        position: const Vec3(0, -50, 0),
        up: const Vec3(0, 0, 1),
        far: 1e9,
      );
      s.update(camera, const ViewportMetrics(800, 600));
      await settle(s);
      expect(s.attributions, ['Old']);
      camera.position = const Vec3(0, -1e7, 0);
      s.update(camera, const ViewportMetrics(800, 600));
      resolver.files['/nested'] = tilesetBytes(
        tile(refine: 'REPLACE', uri: 'new'),
      );
      camera.position = const Vec3(0, -50, 0);
      s.update(camera, const ViewportMetrics(800, 600));
      await settle(s);
      expect(resolver.reads, contains('/new'));
      expect(s.attributions, ['New']);
    },
  );

  test('tileset error controls appearance before root refinement', () async {
    final resolver = MemoryResolver({'/parent': triangleModel()});
    final streamer = Tiles3DStreamer(
      tileset: await source(tile(refine: 'REPLACE', uri: 'parent')),
      services: AssetServices(resolver: resolver),
    );
    addTearDown(streamer.dispose);
    final camera = PerspectiveCamera(
      position: const Vec3(0, -1000000, 0),
      up: const Vec3(0, 0, 1),
      far: 1e9,
    );
    streamer.update(camera, const ViewportMetrics(800, 600));
    await settle(streamer);
    expect(resolver.reads, isEmpty);
    expect(streamer.visible, isEmpty);
    camera.position = const Vec3(0, -1000, 0);
    streamer.update(camera, const ViewportMetrics(800, 600));
    await settle(streamer);
    expect(streamer.visible.keys, ['0']);
  });
  for (final (label, changes) in [
    ('default scene', <String, Object?>{}),
    (
      'unused meshes',
      <String, Object?>{
        'nodes': [{}],
        'scenes': [{}],
      },
    ),
    (
      'alternate scene',
      <String, Object?>{
        'scenes': [
          {},
          {
            'nodes': [0],
          },
        ],
      },
    ),
  ]) {
    test('LRU eviction accounts for $label when the view returns', () async {
      final resolver = MemoryResolver({
        '/left': triangleModel(changes: changes),
        '/right': triangleModel(changes: changes),
      });
      Map<String, Object?> side(String uri, double x) =>
          tile(uri: uri)
            ..['boundingVolume'] = {
              'sphere': [x, 0, 0, 3],
            };
      final root =
          tile(
              refine: 'REPLACE',
              children: [side('left', -50), side('right', 50)],
            )
            ..['boundingVolume'] = {
              'sphere': [0, 0, 0, 100],
            };
      final streamer = Tiles3DStreamer(
        tileset: await source(root),
        services: AssetServices(resolver: resolver),
        budget: Tiles3DBudget(
          maxDecodedBytes: 1024,
          perTileDecodedBytes: 1024,
          maxResidentBytes: 1024,
          perTileResidentBytes: 1024,
        ),
      );
      addTearDown(streamer.dispose);
      for (final x in [-50.0, 50.0, -50.0]) {
        streamer.update(
          PerspectiveCamera(
            position: Vec3(x, -10, 0),
            target: Vec3(x, 0, 0),
            up: const Vec3(0, 0, 1),
          ),
          const ViewportMetrics(100, 100),
        );
        await settle(streamer);
        expect(streamer.visible.length, 1);
        expect(
          streamer.stats.cachedBytes + streamer.stats.reservedBytes,
          lessThanOrEqualTo(1024),
        );
      }
      expect(resolver.reads, ['/left', '/right', '/left']);
    });
  }
  test('content requests respect the current host reference policy', () async {
    final manifest = AssetScope(
      services: AssetServices(
        policy: AllowReferences(),
        resolver: MemoryResolver({
          '/tileset': tilesetBytes(
            tile(refine: 'ADD', uri: 'https://other.test/model.glb'),
          ),
        }),
      ),
    );
    final tileset = await manifest
        .load(Tiles3D.tileset(Uri.parse('https://tiles.test/tileset')))
        .result;
    await manifest.close();
    final resolver = MemoryResolver({'/model.glb': triangleModel()});
    final streamer = Tiles3DStreamer(
      tileset: tileset,
      services: AssetServices(resolver: resolver),
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
    expect(resolver.reads, isEmpty);
    expect(streamer.failures.single.code, AssetLoadError.forbiddenReference);
  });
  const viewport = ViewportMetrics(800, 600);
  PerspectiveCamera camera([double distance = 50]) => PerspectiveCamera(
    position: Vec3(0, -distance, 0),
    target: Vec3.zero,
    up: const Vec3(0, 0, 1),
    far: 20000,
  );
  test(
    'cached camera changes notify once and unchanged frames stay quiet',
    () async {
      final notices = <Tiles3DStats>[];
      late final Tiles3DStreamer streamer;
      streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            refine: 'REPLACE',
            uri: 'parent',
            error: 10,
            children: [
              tile(uri: 'a'),
              tile(uri: 'b'),
            ],
          ),
        ),
        services: AssetServices(
          resolver: MemoryResolver({
            '/parent': triangleModel(),
            '/a': triangleModel(),
            '/b': triangleModel(),
          }),
        ),
        onChanged: () => notices.add(streamer.stats),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(), viewport);
      await settle(streamer);
      await flush();
      expect(streamer.visible.length, 2);
      notices.clear();
      streamer.update(camera(10000), viewport);
      await flush();
      expect(streamer.visible.keys, ['0']);
      expect(notices, hasLength(1));
      expect(notices.single.visibleTiles, 1);
      notices.clear();
      streamer.update(camera(10000), viewport);
      await flush();
      expect(notices, isEmpty);
      final away = camera(10000)..target = const Vec3(0, -20000, 0);
      streamer.update(away, viewport);
      await flush();
      expect(notices, hasLength(1));
      expect(notices.single.visibleTiles, 0);
    },
  );
  test(
    'REPLACE retains parent through child failure and refines after explicit retry',
    () async {
      final resolver = MemoryResolver({
        '/parent.glb': triangleModel(),
        '/a.glb': triangleModel(),
      });
      final streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            refine: 'REPLACE',
            uri: 'parent.glb',
            error: 10,
            children: [
              tile(uri: 'a.glb'),
              tile(uri: 'b.glb'),
            ],
          ),
        ),
        services: AssetServices(resolver: resolver),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(10000), viewport);
      await settle(streamer);
      expect(streamer.visible.keys, ['0']);
      streamer.update(camera(), viewport);
      await settle(streamer);
      expect(streamer.visible.keys, ['0']);
      expect(streamer.failures.length, 1);
      resolver.files['/b.glb'] = triangleModel();
      streamer.retryFailed();
      await settle(streamer);
      expect(streamer.visible.keys.toSet(), {'0/0', '0/1'});
      streamer.update(camera(10000), viewport);
      await settle(streamer);
      expect(streamer.visible.keys, ['0']);
    },
  );
  test('empty nodes with zero error traverse arbitrary child counts', () async {
    final resolver = MemoryResolver({
      for (var i = 0; i < 7; i++) '/$i.glb': triangleModel(),
    });
    final streamer = Tiles3DStreamer(
      tileset: await source(
        tile(
          refine: 'ADD',
          children: [for (var i = 0; i < 7; i++) tile(uri: '$i.glb')],
        ),
      ),
      services: AssetServices(resolver: resolver),
    );
    addTearDown(streamer.dispose);
    streamer.update(camera(), viewport);
    await settle(streamer);
    expect(streamer.visible.length, 7);
    expect(resolver.reads.length, 7);
  });
  test(
    'ADD descendants cannot prematurely replace a ready REPLACE ancestor',
    () async {
      final gate = Completer<void>();
      final resolver =
          MemoryResolver({
              for (final name in ['parent', 'child', 'detail', 'sibling'])
                '/$name.glb': triangleModel(),
            })
            ..beforeRead = (uri, _) async {
              if (uri.path == '/detail.glb') await gate.future;
            };
      final streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            refine: 'REPLACE',
            uri: 'parent.glb',
            error: 10,
            children: [
              tile(
                refine: 'ADD',
                uri: 'child.glb',
                error: 10,
                children: [tile(uri: 'detail.glb')],
              ),
              tile(uri: 'sibling.glb'),
            ],
          ),
        ),
        services: AssetServices(resolver: resolver),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(10000), viewport);
      await settle(streamer);
      streamer.update(camera(), viewport);
      await flush();
      expect(streamer.visible.keys, ['0']);
      gate.complete();
      await settle(streamer);
      expect(streamer.visible.keys.toSet(), {'0/0', '0/0/0', '0/1'});
    },
  );
  test(
    'budget refusal preserves parent and camera exit evicts unused payloads',
    () async {
      final streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            refine: 'REPLACE',
            uri: 'a.glb',
            error: 10,
            children: [
              tile(uri: 'b.glb'),
              tile(uri: 'c.glb'),
            ],
          ),
        ),
        services: AssetServices(
          resolver: MemoryResolver({
            for (final name in ['a', 'b', 'c']) '/$name.glb': triangleModel(),
          }),
        ),
        budget: Tiles3DBudget(
          maxDecodedBytes: 1024,
          perTileDecodedBytes: 1024,
          maxResidentBytes: 1024,
          perTileResidentBytes: 1024,
        ),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(), viewport);
      await settle(streamer);
      expect(streamer.visible.keys, ['0']);
      expect(streamer.stats.budgetLimited, isTrue);
      final away = camera()..target = const Vec3(0, -200, 0);
      streamer.update(away, viewport);
      expect(streamer.visible, isEmpty);
      expect(streamer.stats.cachedBytes, lessThanOrEqualTo(1024));
    },
  );
  test(
    'cancelled physical reads retain slots across source replacement',
    () async {
      final gate = Completer<void>(), arrived = Completer<void>();
      var physical = 0, peak = 0;
      final resolver =
          MemoryResolver({
              '/slow.glb': triangleModel(),
              '/fast.glb': triangleModel(),
            })
            ..beforeRead = (uri, _) async {
              physical++;
              if (physical > peak) peak = physical;
              try {
                if (uri.path == '/slow.glb') {
                  arrived.complete();
                  await gate.future;
                }
              } finally {
                physical--;
              }
            };
      final streamer = Tiles3DStreamer(
        tileset: await source(tile(refine: 'REPLACE', uri: 'slow.glb')),
        services: AssetServices(resolver: resolver),
        budget: Tiles3DBudget(maxRequests: 1),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(), viewport);
      await arrived.future;
      streamer.replaceTileset(
        await source(tile(refine: 'REPLACE', uri: 'fast.glb')),
      );
      streamer.update(camera(), viewport);
      await flush();
      expect(resolver.reads, ['/slow.glb']);
      expect(streamer.stats.activeRequests, 1);
      gate.complete();
      await settle(streamer);
      expect(resolver.reads, ['/slow.glb', '/fast.glb']);
      expect(peak, 1);
      expect(streamer.visible.length, 1);
    },
  );
  test(
    'failures do not spin and retries stop at the configured attempt count',
    () async {
      final resolver = MemoryResolver({});
      final streamer = Tiles3DStreamer(
        tileset: await source(tile(refine: 'REPLACE', uri: 'missing')),
        services: AssetServices(resolver: resolver),
        budget: Tiles3DBudget(maxAttempts: 2),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(), viewport);
      await settle(streamer);
      streamer.update(camera(), viewport);
      await settle(streamer);
      expect(resolver.reads.length, 1);
      streamer.retryFailed();
      await settle(streamer);
      expect(resolver.reads.length, 2);
      streamer.retryFailed();
      await settle(streamer);
      expect(resolver.reads.length, 2);
      expect(streamer.failures.single.attempts, 2);
    },
  );
}

class AllowReferences extends SourcePolicy {
  @override
  void validate(Uri from, Uri to, {String? fieldPath}) {}
}

class HeaderResolver extends MemoryResolver {
  final Map<String, String> headers;
  HeaderResolver(super.files, this.headers);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    final source = await super.read(uri, context);
    return ResolvedSource(
      effectiveUri: source.effectiveUri,
      bytes: source.bytes,
      headers: headers,
    );
  }
}

class MetadataHeaders extends MemoryResolver {
  MetadataHeaders(super.files);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    final source = await super.read(uri, context);
    return ResolvedSource(
      effectiveUri: source.effectiveUri,
      bytes: source.bytes,
      headers: uri.path == '/nested' ? {'cache-control': 'no-store'} : const {},
    );
  }
}
