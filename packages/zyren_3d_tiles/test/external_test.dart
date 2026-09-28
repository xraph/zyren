import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';

Future<Tileset3D> open(MemoryResolver resolver, {Tiles3DLimits? limits}) async {
  final scope = AssetScope(services: AssetServices(resolver: resolver));
  try {
    return await scope
        .load(
          Tiles3D.tileset(Uri.parse('https://tiles.test/root'), limits: limits),
        )
        .result;
  } finally {
    await scope.close();
  }
}

Future<void> settle(Tiles3DStreamer streamer) async {
  for (var i = 0; i < 500; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (streamer.stats.activeRequests == 0) return;
  }
  fail('External tileset did not settle.');
}

const viewport = ViewportMetrics(800, 600);
PerspectiveCamera camera([double x = 0]) => PerspectiveCamera(
  position: Vec3(x, -50, 0),
  target: Vec3(x, 0, 0),
  up: const Vec3(0, 0, 1),
  far: 1e8,
);

void main() {
  test(
    'extensionless external hierarchy composes transforms and effective base URI',
    () async {
      final resolver = RedirectResolver({
        '/root': tilesetBytes(
          tile(
            refine: 'REPLACE',
            uri: 'redirect',
            transform: Mat4.compose(
              const Vec3(6378137, 0, 0),
              Quat.identity,
              Vec3.one,
            ).storage,
          ),
        ),
        '/folder/catalog': tilesetBytes(
          tile(
            uri: 'mesh',
            transform: Mat4.compose(
              const Vec3(10, 0, 0),
              Quat.identity,
              Vec3.one,
            ).storage,
          ),
        ),
        '/folder/mesh': triangleModel(),
      });
      final streamer = Tiles3DStreamer(
        tileset: await open(resolver),
        services: AssetServices(resolver: resolver),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(6378137), viewport);
      await settle(streamer);
      expect(streamer.failures, isEmpty);
      expect(streamer.visible, hasLength(1));
      Object3D node = streamer.visible.values.single;
      var world = Mat4.identity();
      while (node is! Mesh) {
        world = world * node.localMatrix;
        node = node.children.single;
      }
      expect(world.storage[12], closeTo(6378148, 1e-7));
      expect(world.storage[13], closeTo(-3, 1e-7));
      expect(world.storage[14], closeTo(2, 1e-7));
      expect(resolver.reads, ['/root', '/folder/catalog', '/folder/mesh']);
      expect(streamer.stats.cachedBytes, greaterThan(512));
    },
  );

  test(
    'external failure retains parent and retries through the nested root',
    () async {
      final resolver = MemoryResolver({
        '/root': tilesetBytes(
          tile(
            refine: 'REPLACE',
            uri: 'parent',
            error: 10,
            children: [tile(uri: 'nested')],
          ),
        ),
        '/parent': triangleModel(),
        '/nested': tilesetBytes(tile(refine: 'REPLACE', uri: 'missing')),
      });
      final streamer = Tiles3DStreamer(
        tileset: await open(resolver),
        services: AssetServices(resolver: resolver),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(), viewport);
      await settle(streamer);
      expect(streamer.visible.keys, ['0']);
      expect(resolver.reads, contains('/missing'));
      resolver.files['/missing'] = triangleModel();
      streamer.retryFailed();
      await settle(streamer);
      expect(streamer.failures, isEmpty);
      expect(streamer.visible, hasLength(1));
      expect(streamer.visible.keys, isNot(contains('0')));
    },
  );

  test(
    'cycles including effective redirect aliases stop with a typed failure',
    () async {
      final resolver = RedirectResolver({
        '/root': tilesetBytes(tile(refine: 'ADD', uri: 'redirect')),
        '/folder/catalog': tilesetBytes(tile(refine: 'ADD', uri: '../root')),
      });
      final streamer = Tiles3DStreamer(
        tileset: await open(resolver),
        services: AssetServices(resolver: resolver),
      );
      addTearDown(streamer.dispose);
      streamer.update(camera(), viewport);
      await settle(streamer);
      expect(streamer.failures.single.code, AssetLoadError.invalidData);
      expect(resolver.reads.length, lessThanOrEqualTo(3));
      expect(streamer.visible, isEmpty);
    },
  );

  test(
    'external hierarchy cannot add children to a content reference or exceed depth',
    () async {
      for (final hasChildren in [true, false]) {
        final resolver = MemoryResolver({
          '/root': tilesetBytes(
            tile(
              refine: 'REPLACE',
              uri: 'nested',
              children: hasChildren ? [tile()] : [],
            ),
          ),
          '/nested': tilesetBytes(tile(refine: 'REPLACE', uri: 'leaf')),
          '/leaf': triangleModel(),
        });
        final streamer = Tiles3DStreamer(
          tileset: await open(
            resolver,
            limits: Tiles3DLimits(maxDepth: hasChildren ? 8 : 1),
          ),
          services: AssetServices(resolver: resolver),
        );
        addTearDown(streamer.dispose);
        streamer.update(camera(), viewport);
        await settle(streamer);
        expect(
          streamer.failures.single.code,
          hasChildren
              ? AssetLoadError.invalidData
              : AssetLoadError.limitExceeded,
        );
        expect(resolver.reads, isNot(contains('/leaf')));
      }
    },
  );

  test(
    'cancelled external reads retain their slot and cannot publish old hierarchy',
    () async {
      final gate = Completer<void>();
      final resolver =
          MemoryResolver({
              '/root': tilesetBytes(tile(refine: 'REPLACE', uri: 'nested')),
              '/nested': tilesetBytes(tile(refine: 'REPLACE', uri: 'leaf')),
              '/leaf': triangleModel(),
            })
            ..beforeRead = (uri, _) async {
              if (uri.path == '/nested') await gate.future;
            };
      final source = await open(resolver);
      final streamer = Tiles3DStreamer(
        tileset: source,
        services: AssetServices(resolver: resolver),
        budget: Tiles3DBudget(maxRequests: 1),
      );
      streamer.update(camera(), viewport);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final closing = streamer.dispose();
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(closed, isFalse);
      gate.complete();
      await closing;
      expect(streamer.visible, isEmpty);
      expect(resolver.reads, isNot(contains('/leaf')));
    },
  );
}

class RedirectResolver extends MemoryResolver {
  RedirectResolver(super.files);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) => super.read(
    uri.path == '/redirect' ? uri.resolve('/folder/catalog') : uri,
    context,
  );
}
