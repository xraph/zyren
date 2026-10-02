import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';
import 'streaming_test.dart' show source, settle, flush;

Mesh mesh(Object3D object) {
  if (object is Mesh) return object;
  return mesh(object.children.first);
}

Future<Tiles3DStreamer> ready({Tiles3DBudget? budget}) async {
  final gate = Completer<void>();
  final resolver =
      MemoryResolver({
          '/parent': triangleModel(
            changes: {
              'asset': {'version': '2.0', 'copyright': 'Parent'},
            },
          ),
          '/child': triangleModel(
            changes: {
              'asset': {'version': '2.0', 'copyright': 'Child'},
            },
          ),
        })
        ..beforeRead = (uri, _) async {
          if (uri.path == '/child') await gate.future;
        };
  final streamer = Tiles3DStreamer(
    tileset: await source(
      tile(
        uri: 'parent',
        refine: 'REPLACE',
        error: 10,
        children: [tile(uri: 'child')],
      ),
    ),
    services: AssetServices(resolver: resolver),
    budget: budget,
    fadeDuration: const Duration(milliseconds: 250),
  );
  addTearDown(streamer.dispose);
  streamer.update(
    camera(50),
    const ViewportMetrics(800, 600),
    elapsed: Duration.zero,
  );
  for (var i = 0; i < 200 && !streamer.visible.containsKey('0'); i++) {
    await flush();
  }
  expect(streamer.visible.keys, {'0'});
  gate.complete();
  await settle(streamer);
  return streamer;
}

PerspectiveCamera camera(double distance) => PerspectiveCamera(
  position: Vec3(0, -distance, 0),
  far: 1e6,
  up: const Vec3(0, 0, 1),
);

void main() {
  test('selection budget refuses refinement without starting a fade', () async {
    final s = await ready(budget: Tiles3DBudget(maxSelectedTiles: 1));
    expect(s.visible.keys, {'0'});
    expect(s.isTransitioning, isFalse);
    expect(s.stats.budgetLimited, isTrue);
    expect(s.selected.length, 1);
  });
  test(
    'replacement restores captured groups and clears transition ownership',
    () async {
      final s = await ready();
      s.update(
        camera(50),
        const ViewportMetrics(800, 600),
        elapsed: const Duration(milliseconds: 125),
      );
      final parent = mesh(s.visible['0']!);
      expect(parent.fragmentCoverage.isFull, isFalse);
      s.replaceTileset(await source(tile(refine: 'REPLACE')));
      expect(parent.fragmentCoverage.isFull, isTrue);
      expect(s.visible, isEmpty);
      expect(s.isTransitioning, isFalse);
    },
  );
  test(
    'refinement retains parent ownership, credits and complementary coverage',
    () async {
      final s = await ready();
      expect(s.visible.keys, {'0', '0/0'});
      expect(s.isTransitioning, isTrue);
      expect(s.attributions, ['Child', 'Parent']);
      final parent = mesh(s.visible['0']!), child = mesh(s.visible['0/0']!);
      final material = parent.material;
      s.update(
        camera(50),
        const ViewportMetrics(800, 600),
        elapsed: const Duration(milliseconds: 125),
      );
      expect(parent.fragmentCoverage.lower, .5);
      expect(child.fragmentCoverage.upper, .5);
      expect(parent.material, same(material));
      s.update(
        camera(50),
        const ViewportMetrics(800, 600),
        elapsed: const Duration(milliseconds: 250),
      );
      expect(s.visible.keys, {'0/0'});
      expect(s.isTransitioning, isFalse);
      expect(s.attributions, ['Child']);
      expect(parent.fragmentCoverage.isFull, isTrue);
      expect(child.fragmentCoverage.isFull, isTrue);
    },
  );
  test(
    'coarsening waits for current fade then retires children without exceeding budget',
    () async {
      final s = await ready();
      s.update(
        camera(3000),
        const ViewportMetrics(800, 600),
        elapsed: const Duration(milliseconds: 100),
      );
      expect(s.isTransitioning, isTrue);
      s.update(
        camera(3000),
        const ViewportMetrics(800, 600),
        elapsed: const Duration(milliseconds: 250),
      );
      expect(s.visible.keys, {'0', '0/0'});
      s.update(
        camera(3000),
        const ViewportMetrics(800, 600),
        elapsed: const Duration(milliseconds: 500),
      );
      expect(s.visible.keys, {'0'});
      expect(s.isTransitioning, isFalse);
      expect(
        s.stats.residentBytes,
        lessThanOrEqualTo(s.budget.maxResidentBytes),
      );
      await s.dispose();
      expect(s.visible, isEmpty);
    },
  );
  test('camera leaving coverage clears a pending fade', () async {
    final s = await ready();
    s.update(
      PerspectiveCamera(
        position: const Vec3(0, -50, 0),
        target: const Vec3(0, -100, 0),
        up: const Vec3(0, 0, 1),
      ),
      const ViewportMetrics(800, 600),
      elapsed: const Duration(milliseconds: 100),
    );
    expect(s.visible, isEmpty);
    expect(s.isTransitioning, isFalse);
  });
}
