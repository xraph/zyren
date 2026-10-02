import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/frame.dart';

void main() {
  test('cloud shadow range follows source far scale for both projections', () {
    for (final camera in <Camera>[
      PerspectiveCamera(near: 1, far: 80000),
      OrthographicCamera(near: 1, far: 80000),
    ]) {
      final frame = CloudFrameState(
        camera: camera,
        worldToEcef: Mat4.identity(),
        correctedCamera: const Vec3(6360100, 0, 0),
        sun: const Vec3(1, 0, 0),
        aspect: 1,
        width: 32,
        height: 32,
        shadowSize: 8,
        cascadeCount: 2,
        shadowFarScale: .25,
      );
      expect(frame.cascades.far, 20000);
      expect(frame.cascades.near, 1);
      expect(frame.data[177], 20000);
    }
    expect(CloudPlugin().shadowFarScale, 1);
    expect(CloudPlugin(shadowFarScale: .25).shadowFarScale, .25);
    for (final invalid in [0.0, -1.0, 1.01, double.nan, double.infinity]) {
      expect(() => CloudPlugin(shadowFarScale: invalid), throwsArgumentError);
    }
  });
}
