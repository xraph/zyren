import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';

void main() {
  final result = buildSectionCaps(
    BoxGeometry(width: 2, height: 2, depth: 2),
    Mat4.identity(),
    [
      ClippingPlane(normal: const Vec3(1, 0, 0)),
      ClippingPlane(normal: const Vec3(0, 1, 0)),
    ],
  );
  if (result.issue != null) {
    throw StateError('Cannot cap this source: ${result.issue!.name}');
  }
  for (final geometry in result.geometries) {
    print('Cap: ${geometry.indices.length ~/ 3} triangles');
  }
}
