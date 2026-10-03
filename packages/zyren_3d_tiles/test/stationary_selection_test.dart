import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';
import 'fixtures.dart';
import 'streaming_test.dart' show source;

class ObservedCamera extends PerspectiveCamera {
  int projectionReads = 0;
  ObservedCamera()
    : super(
        position: const Vec3(0, -50, 0),
        target: Vec3.zero,
        up: const Vec3(0, 0, 1),
        far: 20000,
      );
  @override
  double get fieldOfView {
    projectionReads++;
    return super.fieldOfView;
  }
}

void main() {
  test(
    'stationary frames reuse selection but view and content changes refresh it',
    () async {
      final tileset = await source(
      tile(error: 100, refine: 'REPLACE', children: [tile(uri: 'child')]),
      );
      final streamer = Tiles3DStreamer(
        tileset: tileset,
        services: AssetServices(resolver: MemoryResolver({})),
      );
      addTearDown(streamer.dispose);
      final camera = ObservedCamera();
      const viewport = ViewportMetrics(800, 600);
      streamer.update(camera, viewport);
      final selected = streamer.selected.keys.toList();
      final firstReads = camera.projectionReads;
      expect(firstReads, greaterThan(0));
      for (var i = 0; i < 20; i++) {
        streamer.update(camera, viewport);
      }
      expect(camera.projectionReads, firstReads);
      expect(streamer.selected.keys, orderedEquals(selected));

      camera.zoom = 2;
      streamer.update(camera, viewport);
      expect(camera.projectionReads, greaterThan(firstReads));
      final zoomReads = camera.projectionReads;
      streamer.update(camera, const ViewportMetrics(400, 600));
      expect(camera.projectionReads, greaterThan(zoomReads));
      final resizeReads = camera.projectionReads;
      streamer.replaceTileset(tileset);
      streamer.update(camera, const ViewportMetrics(400, 600));
      expect(camera.projectionReads, greaterThan(resizeReads));
    },
  );
}
