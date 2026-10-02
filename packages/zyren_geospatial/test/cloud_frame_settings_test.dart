import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/frame.dart';

void main() {
  for (final scale in [.25, 1.0]) {
    for (final horizon in [false, true]) {
      test(
        'shadow frames survive globe zoom with scale=$scale horizon=$horizon',
        () {
          const radius = 6378137.0;
          final camera = PerspectiveCamera(
            position: const Vec3(radius + 1500, 0, 0),
            target: horizon ? const Vec3(radius + 1500, 0, 10000) : Vec3.zero,
            up: horizon ? const Vec3(1, 0, 0) : const Vec3(0, 0, 1),
            near: 1,
            far: 1e9,
          );
          final controls = GlobeControls(
            camera,
            viewport: const ViewportMetrics(800, 600),
          );
          addTearDown(controls.dispose);
          controls.update(1 / 60);
          for (final delta in [400.0, -400.0]) {
            for (var i = 0; i < 64; i++) {
              controls.handleWheel(const ViewportPoint(400, 300), delta);
              controls.update(1 / 60);
              final frame = CloudFrameState(
                camera: camera,
                worldToEcef: Mat4.identity(),
                correctedCamera: camera.position,
                sun: const Vec3(1, 0, 0),
                aspect: 4 / 3,
                width: 64,
                height: 48,
                shadowSize: 16,
                cascadeCount: 3,
                shadowFarScale: scale,
              );
              expect(frame.data.every((v) => v.isFinite), true);
              expect(
                frame.data[177],
                greaterThan(frame.data[176]),
                reason:
                    'Float32 shadow clip interval at ${camera.position.length}',
              );
              expect(frame.cascades.far, lessThanOrEqualTo(camera.far));
              expect(
                frame.cascades.far - frame.cascades.near,
                greaterThanOrEqualTo((camera.far - camera.near) * .0001),
              );
            }
            if (delta > 0) {
              expect(camera.position.length, greaterThan(radius * 2));
            }
          }
        },
      );
    }
  }
  test(
    'cloud shadow range scales the visible clip interval for both projections',
    () {
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
        expect(frame.cascades.far, 20000.75);
        expect(frame.cascades.near, 1);
        expect(frame.data[177], 20000.75);
      }
      expect(CloudPlugin().shadowFarScale, 1);
      expect(CloudPlugin(shadowFarScale: .25).shadowFarScale, .25);
      for (final invalid in [0.0, -1.0, 1.01, double.nan, double.infinity]) {
        expect(() => CloudPlugin(shadowFarScale: invalid), throwsArgumentError);
      }
    },
  );
}
