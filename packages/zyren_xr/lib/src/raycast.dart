import 'package:zyren/zyren.dart';

import 'models.dart';

/// A native plane estimate in session metres. This is not pixel visibility.
final class XrRaycastHit {
  final String? planeId;
  final XrPose pose;
  final double distance;
  XrRaycastHit.fromMessage(Object? value) : this._(messageMap(value));
  XrRaycastHit._(Map<Object?, Object?> map)
    : planeId = map['planeId'] as String?,
      pose = XrPose(_numbers(map['transform'])),
      distance = (map['distance'] as num).toDouble() {
    if (!distance.isFinite || distance < 0) {
      throw const FormatException('Invalid native hit distance.');
    }
  }
  Map<String, Object?> toJson() => {
    'planeId': planeId,
    'sourceId': null,
    'transform': pose.matrix,
    'distance': distance,
    'coverage': 'native-plane-geometry-estimate',
    'pixelVisibility': 'unknown',
  };
}

final class XrRaycastResult {
  final String presenterId;
  final int frameId, epoch, sessionRevision, originEpoch, omittedHits;
  final double frameTimestamp, sensorTimestamp;

  /// Observation time of the frame used for the raycast, on the adapter clock.
  /// Raw sensor time can have a different timebase on ARCore.
  final double queryTimestamp;
  final List<XrRaycastHit> hits;
  XrRaycastResult.fromMessage(Object? value) : this._(messageMap(value));
  XrRaycastResult._(Map<Object?, Object?> map)
    : presenterId = messageString(map, 'presenterId'),
      frameId = _integer(map, 'frameId'),
      epoch = _integer(map, 'epoch'),
      sessionRevision = _integer(map, 'sessionRevision'),
      originEpoch = _integer(map, 'originEpoch'),
      omittedHits = _integer(map, 'omittedHits'),
      frameTimestamp = (map['frameTimestamp'] as num).toDouble(),
      sensorTimestamp = (map['sensorTimestamp'] as num).toDouble(),
      queryTimestamp =
          ((map['queryTimestamp'] ?? map['sensorTimestamp']) as num).toDouble(),
      hits = List.unmodifiable(
        (map['hits'] as List).map(XrRaycastHit.fromMessage),
      ) {
    if (presenterId.isEmpty ||
        hits.length > 16 ||
        !frameTimestamp.isFinite ||
        frameTimestamp < 0 ||
        !sensorTimestamp.isFinite ||
        sensorTimestamp < 0 ||
        !queryTimestamp.isFinite ||
        queryTimestamp < frameTimestamp ||
        queryTimestamp - frameTimestamp > .5 ||
        map['coverage'] != 'native-plane-geometry-estimate') {
      throw const FormatException('Invalid native raycast result.');
    }
  }
}

/// Bounded plane-local geometry. Apply [pose] to place it in session space.
final class XrPlaneGeometry {
  final String planeId;
  final int sessionRevision;
  final double frameTimestamp;
  final XrPose pose;
  final List<double> vertices, boundary;
  final List<int> indices;
  XrPlaneGeometry.fromMessage(Object? value) : this._(messageMap(value));
  XrPlaneGeometry._(Map<Object?, Object?> map)
    : planeId = messageString(map, 'planeId'),
      sessionRevision = _integer(map, 'sessionRevision'),
      frameTimestamp = (map['frameTimestamp'] as num).toDouble(),
      pose = XrPose(_numbers(map['transform'])),
      vertices = List.unmodifiable(_numbers(map['vertices'])),
      boundary = List.unmodifiable(_numbers(map['boundary'])),
      indices = List.unmodifiable((map['indices'] as List).cast<int>()) {
    if (planeId.isEmpty ||
        !frameTimestamp.isFinite ||
        frameTimestamp < 0 ||
        vertices.length > 4096 * 3 ||
        vertices.length % 3 != 0 ||
        boundary.length > 1024 * 3 ||
        boundary.length % 3 != 0 ||
        indices.length > 4096 * 3 ||
        indices.length % 3 != 0 ||
        vertices.any((v) => !v.isFinite) ||
        boundary.any((v) => !v.isFinite) ||
        indices.any((v) => v < 0 || v >= vertices.length ~/ 3)) {
      throw const FormatException('Invalid bounded plane geometry.');
    }
  }

  BufferGeometry toGeometry() => BufferGeometry(
    positions: vertices,
    normals: [
      for (var i = 0; i < vertices.length ~/ 3; i++) ...[0, 1, 0],
    ],
    indices: indices,
  );
}

List<double> _numbers(Object? value) =>
    (value as List).cast<num>().map((v) => v.toDouble()).toList();
int _integer(Map<Object?, Object?> map, String key) {
  final value = map[key];
  if (value is! int || value < 0) throw FormatException('Invalid $key.');
  return value;
}
