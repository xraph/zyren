import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  final horizon = EllipsoidHorizon(
    ellipsoid: Ellipsoid(1, 1, 1),
    minimumHeight: 0,
  );
  test('whole bounds behind the globe are culled conservatively', () {
    expect(
      horizon.isSphereVisible(const Vec3(2, 0, 0), const Vec3(-1, 0, 0), .01),
      isFalse,
    );
    expect(
      horizon.isSphereVisible(const Vec3(2, 0, 0), const Vec3(1, 0, 0), .01),
      isTrue,
    );
    expect(
      horizon.isSphereVisible(
        const Vec3(2, 0, 0),
        Vec3(.5, math.sqrt(.75), 0),
        .1,
      ),
      isTrue,
    );
    expect(
      horizon.isSphereVisible(const Vec3(2, 0, 0), const Vec3(-1, 2, 0), .1),
      isTrue,
    );
    expect(
      horizon.isSphereVisible(const Vec3(2, 0, 0), const Vec3(-1, 0, 0), 2),
      isTrue,
    );
  });
  test(
    'below-surface cameras, local bounds and high mountains remain conservative',
    () {
      expect(
        horizon.isSphereVisible(
          const Vec3(.99, 0, 0),
          const Vec3(-1, 0, 0),
          .01,
        ),
        isTrue,
      );
      expect(
        horizon.isSphereVisible(const Vec3(2, 0, 0), Vec3.zero, .01),
        isTrue,
      );
      const earth = EllipsoidHorizon();
      expect(
        earth.isSphereVisible(
          const Vec3(6379000, 0, 0),
          const Vec3(6378000, 50000, 0),
          15000,
        ),
        isTrue,
      );
      expect(
        earth.isSphereVisible(
          const Vec3(7000000, 0, 0),
          const Vec3(-6378137, 0, 0),
          100,
        ),
        isFalse,
      );
    },
  );
  test('culling a volume also occludes its sampled surface', () {
    const camera = Vec3(3, 0, 0);
    for (var longitude = 0.0; longitude < 2 * math.pi; longitude += .1) {
      final center = Vec3(math.cos(longitude), math.sin(longitude), 0);
      if (horizon.isSphereVisible(camera, center, .05)) continue;
      for (var a = 0.0; a < 2 * math.pi; a += .1) {
        final point = center + Vec3(.05 * math.cos(a), .05 * math.sin(a), 0);
        final delta = point - camera;
        final t = (-camera.dot(delta) / delta.length2).clamp(0.0, 1.0);
        expect((camera + delta * t).length, lessThan(1));
      }
    }
  });
}
