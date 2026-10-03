import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'cloud.dart';

final class PointCloudHit {
  final (Uri, String, int) identity;
  final int dataIndex;
  final Vec3 sourcePoint, worldPoint;
  final double distance, raySeparation;
  const PointCloudHit(
    this.identity,
    this.sourcePoint,
    this.worldPoint,
    this.distance,
    this.raySeparation, {
    this.dataIndex = 0,
  });
}

/// A scoped native marker object. Close removes it from its current parent.
/// Attach [object] to your scene; the backend owns uploaded geometry caches.
final class ScenePointCloud {
  final PointCloudData data;
  final Vec3 sourceOrigin;
  final Group object;
  final Points _points;
  final double maxDisplayError;
  bool _closed = false;
  final AttachmentScope _lifetime = AttachmentScope();
  ScenePointCloud._(
    this.data,
    this.sourceOrigin,
    this.object,
    this._points,
    this.maxDisplayError,
  );

  factory ScenePointCloud({
    required PointCloudData data,
    Vec3? sourceOrigin,
    PointsMaterial? material,
    double displayErrorLimit = .001,
  }) {
    if (!displayErrorLimit.isFinite || displayErrorLimit < 0) {
      throw ArgumentError(
        'Display error limit must be finite and nonnegative.',
      );
    }
    final origin = sourceOrigin ?? data.pointAt(0);
    if (!origin.isFinite) throw ArgumentError('Source origin must be finite.');
    var error = 0.0;
    final local = <Vec3>[];
    for (var i = 0; i < data.count; i++) {
      final relative = data.pointAt(i) - origin;
      final f32 = Float32List.fromList([relative.x, relative.y, relative.z]);
      final rounded = Vec3(f32[0], f32[1], f32[2]);
      final difference = rounded.distanceTo(relative);
      if (!rounded.isFinite ||
          !difference.isFinite ||
          difference > displayErrorLimit) {
        throw ArgumentError(
          'Point $i exceeds the display error limit; partition the cloud.',
        );
      }
      if (difference > error) error = difference;
      local.add(rounded);
    }
    final points = Points(
      PointGeometry(points: local),
      material ?? PointsMaterial(),
      name: 'point samples',
    );
    final root = Group(name: data.sourceUri.toString())..position = origin;
    root.add(points);
    return ScenePointCloud._(data, origin, root, points, error);
  }

  bool get isClosed => _closed;
  Registration onClose(void Function() callback) => _lifetime.onClose(callback);

  /// Tests source samples with a world-space radius, not the screen marker size.
  /// Ties select the earliest source record. Supply the active scene clip planes.
  PointCloudHit? pick(
    Ray ray, {
    required double radius,
    double near = 0,
    double far = double.infinity,
    Iterable<ClippingPlane> clippingPlanes = const [],
    LayerMask? layers,
  }) {
    if (_closed) throw StateError('Point cloud has closed.');
    if (!radius.isFinite ||
        radius <= 0 ||
        !near.isFinite ||
        near < 0 ||
        far.isNaN ||
        far < near) {
      throw ArgumentError('Invalid point query interval or radius.');
    }
    var effectiveLayers = LayerMask.all;
    var clipping = true;
    for (Object3D? node = _points; node != null; node = node.parent) {
      if (!node.visible) return null;
      effectiveLayers = effectiveLayers.intersection(node.layers);
      clipping = clipping && node.clippingEnabled;
    }
    if (layers != null && !effectiveLayers.intersects(layers)) return null;
    final matrix = _points.worldMatrix.storage;
    final planes = clipping ? clippingPlanes.toList() : <ClippingPlane>[];
    PointCloudHit? nearest;
    for (var i = 0; i < data.count; i++) {
      final source = data.pointAt(i), p = source - sourceOrigin;
      final world = Vec3(
        matrix[0] * p.x + matrix[4] * p.y + matrix[8] * p.z + matrix[12],
        matrix[1] * p.x + matrix[5] * p.y + matrix[9] * p.z + matrix[13],
        matrix[2] * p.x + matrix[6] * p.y + matrix[10] * p.z + matrix[14],
      );
      if (!world.isFinite) {
        throw StateError('Point transform exceeds finite coordinates.');
      }
      if (planes.any((plane) => plane.distanceTo(world) < 0)) continue;
      final delta = world - ray.origin;
      final distance = delta.dot(ray.direction);
      if (distance < near ||
          distance > far ||
          (nearest != null && distance >= nearest.distance)) {
        continue;
      }
      final separation = (delta - ray.direction * distance).length;
      if (separation <= radius) {
        nearest = PointCloudHit(
          data.identityAt(i),
          source,
          world,
          distance,
          separation,
          dataIndex: i,
        );
      }
    }
    return nearest;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _lifetime.close();
    object.parent?.remove(object);
    object.remove(_points);
  }
}
