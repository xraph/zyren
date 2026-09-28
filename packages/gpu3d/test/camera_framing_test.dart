import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

List<double> project(Camera camera, Vec3 point, double aspect) {
  final p = point - camera.position;
  final m = camera.viewProjection(aspect).storage;
  final w = m[3] * p.x + m[7] * p.y + m[11] * p.z + m[15];
  return [
    for (var row = 0; row < 3; row++)
      (m[row] * p.x + m[row + 4] * p.y + m[row + 8] * p.z + m[row + 12]) / w,
  ];
}

void main() {
  final box = Bounds3(const Vec3(-2, -1, -1), const Vec3(2, 1, 1));

  test(
    'perspective framing accounts for front corners and viewport aspect',
    () {
      for (final (aspect, distance) in [(1.0, 3.0), (.5, 5.0), (2.0, 2.0)]) {
        final camera = PerspectiveCamera(fieldOfView: math.pi / 2);
        expect(camera.frameBounds(box, aspect: aspect, padding: 1), isTrue);
        expect(camera.position.x, 0);
        expect(camera.position.y, 0);
        expect(camera.position.z, closeTo(distance, 1e-12));
        expect(camera.target, Vec3.zero);
        for (final corner in box.corners) {
          final ndc = project(camera, corner, aspect);
          expect(ndc[0].abs(), lessThanOrEqualTo(1 + 1e-12));
          expect(ndc[1].abs(), lessThanOrEqualTo(1 + 1e-12));
          expect(ndc[2], inInclusiveRange(0, 1));
        }
      }
    },
  );

  test('orthographic framing preserves zoom and fits a narrow viewport', () {
    final camera = OrthographicCamera(zoom: 2);
    expect(camera.frameBounds(box, aspect: .5, padding: 1), isTrue);
    expect(camera.zoom, 2);
    expect(camera.verticalSize, 16);
    expect(camera.position, const Vec3(0, 0, 5));
    final ndc = project(camera, const Vec3(2, 1, 1), .5);
    expect(ndc.take(2), [1, .25]);
    expect(ndc[2], inInclusiveRange(0, 1));
  });

  test('oblique framing preserves roll and fits corners at large origins', () {
    const origin = Vec3(6378137, -6378137, 6378137);
    final bounds = Bounds3(
      origin - const Vec3(4, 1, 6),
      origin + const Vec3(4, 1, 6),
    );
    for (final aspect in [.4, 1.0, 3.0]) {
      for (final camera in <Camera>[
        PerspectiveCamera(
          position: origin + const Vec3(3, 4, 5),
          target: origin,
          up: const Vec3(0, 0, 1),
        ),
        OrthographicCamera(
          position: origin + const Vec3(3, 4, 5),
          target: origin,
          up: const Vec3(0, 0, 1),
          zoom: 1.7,
        ),
      ]) {
        final backward = (camera.position - camera.target).normalized();
        camera.frameBounds(bounds, aspect: aspect, padding: 1.2);
        expect(camera.target, origin);
        expect(camera.up, const Vec3(0, 0, 1));
        expect(
          (camera.position - camera.target).normalized().distanceTo(backward),
          lessThan(1e-9),
        );
        for (final corner in bounds.corners) {
          final ndc = project(camera, corner, aspect);
          expect(ndc[0].abs(), lessThanOrEqualTo(1 / 1.2 + 1e-9));
          expect(ndc[1].abs(), lessThanOrEqualTo(1 / 1.2 + 1e-9));
          expect(ndc[2], inInclusiveRange(0, 1));
        }
      }
    }
  });

  test('point and flat bounds frame without singular cameras or clipping', () {
    for (final bounds in [
      Bounds3(const Vec3(2, 3, 4), const Vec3(2, 3, 4)),
      Bounds3(const Vec3(-2, 0, 0), const Vec3(2, 0, 0)),
      Bounds3(const Vec3(0, 0, -10000), const Vec3(0, 0, 10000)),
    ]) {
      for (final camera in <Camera>[
        PerspectiveCamera(),
        OrthographicCamera(),
      ]) {
        camera.frameBounds(bounds, aspect: 2, minimumExtent: .2);
        expect(camera.position.distanceTo(camera.target), greaterThan(0));
        for (final point in bounds.corners) {
          expect(Frustum.fromCamera(camera, 2).containsPoint(point), isTrue);
        }
      }
    }
  });

  test('empty bounds and rejected arguments leave the camera unchanged', () {
    final camera = PerspectiveCamera();
    final revision = camera.revision;
    expect(camera.frameBounds(const Bounds3.empty(), aspect: 1), isFalse);
    for (final bad in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => camera.frameBounds(box, aspect: bad), throwsArgumentError);
      expect(
        () => camera.frameBounds(box, aspect: 1, minimumExtent: bad),
        throwsArgumentError,
      );
    }
    for (final bad in [.5, double.nan, double.infinity]) {
      expect(
        () => camera.frameBounds(box, aspect: 1, padding: bad),
        throwsArgumentError,
      );
    }
    final huge = Bounds3(
      const Vec3(-1e308, -1e308, -1e308),
      const Vec3(1e308, 1e308, 1e308),
    );
    expect(() => camera.frameBounds(huge, aspect: 1), throwsArgumentError);
    expect(camera.revision, revision);
  });

  test(
    'framing adjusts clip planes in either direction without setter failure',
    () {
      final camera = PerspectiveCamera(near: 100, far: 101);
      camera.frameBounds(box, aspect: 1);
      expect(camera.near, lessThan(100));
      expect(camera.far, lessThan(100));
      final near = camera.near;
      camera.frameBounds(
        Bounds3(const Vec3(-1e5, -1e5, -1e5), const Vec3(1e5, 1e5, 1e5)),
        aspect: 1,
      );
      expect(camera.near, greaterThan(near));
      expect(camera.near, lessThan(camera.far));
    },
  );
}
