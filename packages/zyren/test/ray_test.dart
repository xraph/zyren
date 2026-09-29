import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('rays normalize direction and reject invalid finite inputs', () {
    final ray = Ray(Vec3.zero, const Vec3(0, 0, 8));
    expect(ray.at(2), const Vec3(0, 0, 2));
    expect(() => Ray(Vec3.zero, Vec3.zero), throwsArgumentError);
    expect(
      () => Ray(const Vec3(double.nan, 0, 0), Vec3.one),
      throwsArgumentError,
    );
    expect(() => ray.at(double.infinity), throwsArgumentError);
  });
  test(
    'box slabs include edges, handle parallel axes and reject behind rays',
    () {
      final bounds = Bounds3(const Vec3(-1, -1, -1), Vec3.one);
      expect(
        Ray(const Vec3(1, 0, 4), const Vec3(0, 0, -1)).intersectBounds(bounds),
        3,
      );
      expect(Ray(Vec3.zero, const Vec3(0, 1, 0)).intersectBounds(bounds), 0);
      expect(
        Ray(const Vec3(2, 0, 4), const Vec3(0, 0, -1)).intersectBounds(bounds),
        isNull,
      );
      expect(
        Ray(const Vec3(0, 0, 4), const Vec3(0, 0, 1)).intersectBounds(bounds),
        isNull,
      );
      expect(
        Ray(Vec3.zero, Vec3.one).intersectBounds(const Bounds3.empty()),
        isNull,
      );
    },
  );
  test(
    'triangle hits include barycentrics, sidedness, edges and tiny geometry',
    () {
      const a = Vec3(-1, -1, 0), b = Vec3(1, -1, 0), c = Vec3(0, 1, 0);
      final ray = Ray(const Vec3(0, 0, 2), const Vec3(0, 0, -1));
      final hit = ray.intersectTriangle(a, b, c, side: MaterialSide.front)!;
      expect(hit.distance, 2);
      expect(hit.point, Vec3.zero);
      expect(hit.barycentric, const Vec3(.25, .25, .5));
      expect(ray.intersectTriangle(a, b, c, side: MaterialSide.back), isNull);
      expect(
        ray.intersectTriangle(c, b, a, side: MaterialSide.back),
        isNotNull,
      );
      expect(ray.intersectTriangle(a, a, c), isNull);
      expect(
        Ray(
          const Vec3(0, 1, 2),
          const Vec3(0, 0, -1),
        ).intersectTriangle(a, b, c),
        isNotNull,
      );
      expect(
        Ray(
          const Vec3(2, 0, 2),
          const Vec3(0, 0, -1),
        ).intersectTriangle(a, b, c),
        isNull,
      );
      expect(
        Ray(
          const Vec3(0, 0, -2),
          const Vec3(0, 0, -1),
        ).intersectTriangle(a, b, c),
        isNull,
      );
      expect(ray.intersectTriangle(a * 1e-9, b * 1e-9, c * 1e-9), isNotNull);
    },
  );
}
