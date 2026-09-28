import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';

/// An analytic HDR studio panorama, so the example needs no external assets.
HdrImageData studioEnvironment() {
  const width = 256, height = 128;
  final pixels = Float32List(width * height * 4);
  final key = const Vec3(-1, 1, 1).normalized();
  final rim = const Vec3(1, .3, -.5).normalized();
  for (var y = 0; y < height; y++) {
    final theta = (y + .5) / height * math.pi;
    for (var x = 0; x < width; x++) {
      final phi = ((x + .5) / width - .5) * math.pi * 2;
      final n = Vec3(
        math.cos(phi) * math.sin(theta),
        math.cos(theta),
        math.sin(phi) * math.sin(theta),
      );
      double dot(Vec3 other) => n.x * other.x + n.y * other.y + n.z * other.z;
      final softbox = 10 * math.exp(40 * (dot(key) - 1));
      final edge = 6 * math.exp(60 * (dot(rim) - 1));
      final sky = .04 + .16 * math.max(n.y, 0);
      final i = (y * width + x) * 4;
      pixels[i] = sky + softbox + .3 * edge;
      pixels[i + 1] = sky * 1.15 + .85 * softbox + .6 * edge;
      pixels[i + 2] = sky * 1.5 + .65 * softbox + edge;
      pixels[i + 3] = 1;
    }
  }
  return HdrImageData(pixels: pixels, size: PhysicalSize(width, height));
}
