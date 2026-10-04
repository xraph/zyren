import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';
import 'streaming_test.dart' show source;

void main() {
  test(
    'large selection refines highest errors within the tile count limit',
    () async {
      final streamer = Tiles3DStreamer(
        tileset: await source(
          tile(
            error: 100000,
            refine: 'REPLACE',
            children: [
              for (var i = 0; i < 128; i++)
                tile(
                  error: (i + 1) * 100.0,
                  uri: 'parent$i',
                  children: [
                    tile(uri: 'child${i}a'),
                    tile(uri: 'child${i}b'),
                  ],
                ),
            ],
          ),
        ),
        services: AssetServices(resolver: MemoryResolver({})),
        budget: Tiles3DBudget(maxSelectedTiles: 169),
      );
      addTearDown(streamer.dispose);
      final camera = PerspectiveCamera(
        position: const Vec3(0, -50, 0),
        target: Vec3.zero,
        up: const Vec3(0, 0, 1),
        far: 20000,
      );
      const viewport = ViewportMetrics(800, 600);
      streamer.update(camera, viewport);
      expect(streamer.selected.length, 169);
      for (var i = 0; i < 128; i++) {
        expect(streamer.selected.containsKey('0/$i/0'), i >= 108);
        expect(streamer.selected.containsKey('0/$i/1'), i >= 108);
      }
      final first = streamer.selected.keys.toList();
      streamer.update(camera, viewport);
      expect(streamer.selected.keys, orderedEquals(first));

      // A new camera and viewport must not reuse priorities from the close view.
      streamer.update(
        PerspectiveCamera(
          position: const Vec3(0, -10000000, 0),
          target: Vec3.zero,
          up: const Vec3(0, 0, 1),
          far: 20000000,
        ),
        const ViewportMetrics(80, 60),
      );
      expect(streamer.selected, isEmpty);
    },
  );
}
