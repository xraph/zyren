import 'dart:math' as math;
import 'package:zyren/zyren.dart';

/// Viewer framing yields between chunks so large meshes keep input responsive.
Future<({Vec3 center, double radius})> modelBounds(
  Object3D root,
  bool Function() cancelled,
) async {
  var low = const Vec3(double.infinity, double.infinity, double.infinity);
  var high = const Vec3(
    double.negativeInfinity,
    double.negativeInfinity,
    double.negativeInfinity,
  );
  final stack = [(root, Mat4.identity())];
  var visited = 0;
  while (stack.isNotEmpty) {
    if (cancelled()) throw LoadCancelled();
    final (object, parent) = stack.removeLast();
    final world = parent * object.localMatrix, m = world.storage;
    if (object is Mesh) {
      final pose = object.captureDeformation();
      final positions = pose == null
          ? object.geometry.positions
          : [for (final corner in pose.bounds.corners) ...corner.storage];
      for (var i = 0; i < positions.length; i += 3) {
        final x = positions[i], y = positions[i + 1], z = positions[i + 2];
        final point = Vec3(
          m[0] * x + m[4] * y + m[8] * z + m[12],
          m[1] * x + m[5] * y + m[9] * z + m[13],
          m[2] * x + m[6] * y + m[10] * z + m[14],
        );
        low = Vec3(
          math.min(low.x, point.x),
          math.min(low.y, point.y),
          math.min(low.z, point.z),
        );
        high = Vec3(
          math.max(high.x, point.x),
          math.max(high.y, point.y),
          math.max(high.z, point.z),
        );
        if (++visited % 8192 == 0) {
          await Future<void>.delayed(Duration.zero);
          if (cancelled()) throw LoadCancelled();
        }
      }
    }
    for (final child in object.children) {
      stack.add((child, world));
    }
  }
  if (!low.isFinite || !high.isFinite) return (center: Vec3.zero, radius: 1.0);
  final radius = (high - low).length / 2;
  if (!radius.isFinite || radius > 1e10) {
    throw StateError('This model exceeds the viewer framing range.');
  }
  return (center: (low + high) / 2, radius: math.max(radius, .001));
}
