import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_splats/zyren_splats.dart';
import 'package:zyren_splats/streaming.dart';

void main() {
  test(
    'Gaussian LOD merges visible chunks with original identities and one global order',
    () async {
      final data = GaussianCloudData(
        sourceUri: Uri.parse('memory:splats'),
        sourceVersion: 'v1',
        splats: [
          for (var i = 0; i < 8; i++)
            GaussianSplat(
              mean: Vec3(i * .1 - .4, 0, -i * .1),
              covariance: GaussianCovariance(xx: .001, yy: .001, zz: .001),
              color: const Color3(1, 0, 0),
            ),
        ],
      );
      final tree = GaussianOctree.fromData(data, samplesPerChunk: 2);
      final stream = SpatialStreamer(root: tree.root, loader: tree.load);
      final plugin = GaussianStreamPlugin(stream: stream);
      final camera = PerspectiveCamera();
      stream.update(camera, PhysicalSize(200, 200));
      await stream.settle();
      final visible = plugin.visibleData!;
      expect(visible.splats.length, 8);
      expect(
        List.generate(8, (i) => visible.identityAt(i)).toSet(),
        List.generate(8, data.identityAt).toSet(),
      );
      final projected = projectGaussians(
        visible,
        camera: camera,
        size: PhysicalSize(200, 200),
      );
      expect(projected.map((p) => p.recordIndex), [7, 6, 5, 4, 3, 2, 1, 0]);
      await stream.close();
      expect(plugin.visibleData, isNull);
    },
  );
}
