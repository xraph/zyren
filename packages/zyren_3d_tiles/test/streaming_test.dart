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
