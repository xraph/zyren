import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// Limits retained coordinate payloads. Parser and geometry overhead are separate.
final class PointCloudLimits {
  final int maxPoints, maxSourceBytes, maxLineBytes, maxCoordinateBytes;
  const PointCloudLimits({
    this.maxPoints = 250000,
    this.maxSourceBytes = 32 * 1024 * 1024,
    this.maxLineBytes = 1024,
    this.maxCoordinateBytes = 6 * 1024 * 1024,
  });

  void validate() {
    RangeError.checkValueInInterval(maxPoints, 1, 250000, 'maxPoints');
    for (final value in [maxSourceBytes, maxLineBytes, maxCoordinateBytes]) {
      RangeError.checkValueInInterval(value, 1, 0x7fffffff);
    }
  }

  void checkCount(int count) {
    if (count > maxPoints || count * 24 > maxCoordinateBytes) {
      throw AssetLoadException(
        AssetLoadError.limitExceeded,
        'Point count or coordinate payload exceeds its budget.',
      );
    }
  }
}

/// Immutable samples in caller-defined source units, without float32 conversion.
final class PointCloudData {
  final Uri sourceUri;
  final String sourceVersion;
  final Float64List _positions;
  final Uint8List? _classifications;
  PointCloudData._(
    this.sourceUri,
    this.sourceVersion,
    this._positions,
    this._classifications,
  );

  factory PointCloudData({
    required Uri sourceUri,
    required String sourceVersion,
    required Iterable<Vec3> points,
    List<int>? classifications,
    PointCloudLimits limits = const PointCloudLimits(),
  }) {
    limits.validate();
    _validateIdentity(sourceUri, sourceVersion);
    final values = <double>[];
    for (final point in points) {
      limits.checkCount(values.length ~/ 3 + 1);
      if (!point.isFinite) {
        throw ArgumentError('Point coordinates must be finite.');
      }
      values.addAll([point.x, point.y, point.z]);
    }
    if (values.isEmpty) throw ArgumentError('A point cloud needs samples.');
    if (classifications != null &&
        (classifications.length != values.length ~/ 3 ||
            classifications.any((v) => v < 0 || v > 255))) {
      throw ArgumentError(
        'Classifications need one byte value per source point.',
      );
    }
    return PointCloudData._(
      sourceUri,
      sourceVersion,
      Float64List.fromList(values),
      classifications == null ? null : Uint8List.fromList(classifications),
    );
  }

  int get count => _positions.length ~/ 3;
  int get coordinateBytes => _positions.lengthInBytes;
  int get classificationBytes => _classifications?.lengthInBytes ?? 0;
  int? classificationAt(int index) {
    identityAt(index);
    return _classifications?[index];
  }

  (Uri, String, int) identityAt(int index) {
    RangeError.checkValidIndex(index, _positions, 'index', count);
    return (sourceUri, sourceVersion, index);
  }

  Vec3 pointAt(int index) {
    identityAt(index);
    return Vec3(
      _positions[index * 3],
      _positions[index * 3 + 1],
      _positions[index * 3 + 2],
    );
  }
}

void _validateIdentity(Uri uri, String version) {
  if (!uri.hasScheme ||
      uri.hasFragment ||
      version.isEmpty ||
      version.length > 1024) {
    throw ArgumentError(
      'Use an absolute URI without a fragment and a nonempty version.',
    );
  }
}
