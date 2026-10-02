import 'package:flutter_test/flutter_test.dart';
import 'package:planet/geospatial_scene.dart';

void main() {
  test('desktop and phone viewports keep their available pixel detail', () {
    expect(geospatialResolutionScale(width: 1600, height: 950), 1);
    expect(geospatialResolutionScale(width: 1179, height: 1600), 1);
    final wide = geospatialResolutionScale(width: 3424, height: 1818);
    expect((3424 * wide).round(), 1920);
    expect((1818 * wide).round(), 1019);
    final square = geospatialResolutionScale(width: 2000, height: 2000);
    expect((2000 * square).round(), 1448);
  });
  test('rounded native dimensions stay inside the effects pixel budget', () {
    for (final (width, height) in [
      (2000.0, 1400.0),
      (1400.0, 2000.0),
      (2234.25, 1190.75),
      (390.0, 700.0),
      (4680.0, 8400.0),
    ]) {
      final scale = geospatialResolutionScale(width: width, height: height);
      final w = (width * scale).round(), h = (height * scale).round();
      expect(w, lessThanOrEqualTo(1920));
      expect(h, lessThanOrEqualTo(1920));
      expect(w * h, lessThanOrEqualTo(2 * 1024 * 1024));
    }
  });
}
