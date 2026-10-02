import 'dart:convert';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';

void main() {
  final measurements = <Map<String, Object>>[];
  for (final width in [64, 128, 256]) {
    final geometry = SphereGeometry(
      widthSegments: width,
      heightSegments: width ~/ 2,
    );
    final planes = [ClippingPlane(normal: const Vec3(0, 1, 0), offset: .123)];
    final samples = <int>[];
    var capTriangles = 0;
    for (var i = 0; i < 6; i++) {
      final watch = Stopwatch()..start();
      final result = buildSectionCaps(geometry, Mat4.identity(), planes);
      watch.stop();
      if (result.issue != null) throw StateError('${result.issue}');
      capTriangles = result.geometries.fold(
        0,
        (n, g) => n + g.indices.length ~/ 3,
      );
      if (i > 0) samples.add(watch.elapsedMicroseconds);
    }
    measurements.add({
      'source_triangles': geometry.indices.length ~/ 3,
      'cap_triangles': capTriangles,
      'samples_us': samples,
    });
  }
  print(
    jsonEncode({
      'os': Platform.operatingSystem,
      'dart': Platform.version,
      'measurements': measurements,
    }),
  );
}
