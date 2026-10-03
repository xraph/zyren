import 'dart:convert';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// Payload admission limits. Dart object and native decoder overhead are separate.
final class PointCloudLimits {
  final int maxPoints, maxSourceBytes, maxLineBytes, maxCoordinateBytes;
  final int maxAttributeBytes, maxMetadataBytes, maxDecodedBytes;
  const PointCloudLimits({
    this.maxPoints = 250000,
    this.maxSourceBytes = 32 * 1024 * 1024,
    this.maxLineBytes = 1024,
    this.maxCoordinateBytes = 6 * 1024 * 1024,
    this.maxAttributeBytes = 32 * 1024 * 1024,
    this.maxMetadataBytes = 4 * 1024 * 1024,
    this.maxDecodedBytes = 64 * 1024 * 1024,
  });

  void validate() {
    RangeError.checkValueInInterval(maxPoints, 1, 250000, 'maxPoints');
    for (final value in [
      maxSourceBytes,
      maxLineBytes,
      maxCoordinateBytes,
      maxAttributeBytes,
      maxMetadataBytes,
      maxDecodedBytes,
    ]) {
      RangeError.checkValueInInterval(value, 1, 128 * 1024 * 1024);
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
/// Source ordinals survive filtering, invalid-record removal and LOD selection.
final class PointCloudData {
  final Uri sourceUri;
  final String sourceVersion;
  final Float64List _positions;
  final Uint8List? _classifications;
  final Int64List _recordIndices;
  final List<Map<String, Object?>>? _attributes;
  final Map<String, Object?> metadata;
  final int attributeBytes, metadataBytes;
  PointCloudData._(
    this.sourceUri,
    this.sourceVersion,
    this._positions,
    this._classifications,
    this._recordIndices,
    this._attributes,
    this.metadata,
    this.attributeBytes,
    this.metadataBytes,
  );

  factory PointCloudData({
    required Uri sourceUri,
    required String sourceVersion,
    required Iterable<Vec3> points,
    List<int>? classifications,
    List<int>? recordIndices,
    List<Map<String, Object?>>? attributes,
    Map<String, Object?> metadata = const {},
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
    final count = values.length ~/ 3;
    if (count == 0) throw ArgumentError('A point cloud needs samples.');
    if (classifications != null &&
        (classifications.length != count ||
            classifications.any((v) => v < 0 || v > 255))) {
      throw ArgumentError(
        'Classifications need one byte value per source point.',
      );
    }
    final indices = recordIndices ?? List.generate(count, (i) => i);
    if (indices.length != count ||
        indices.any((i) => i < 0) ||
        indices.toSet().length != count) {
      throw ArgumentError(
        'Each sample needs a unique nonnegative source ordinal.',
      );
    }
    if (attributes != null && attributes.length != count) {
      throw ArgumentError('Attributes need one entry per retained sample.');
    }
    final attrBytes =
        attributes?.fold<int>(
          0,
          (sum, a) => sum + utf8.encode(jsonEncode(a)).length,
        ) ??
        0;
    final metaBytes = utf8.encode(jsonEncode(metadata)).length;
    if (attrBytes > limits.maxAttributeBytes ||
        metaBytes > limits.maxMetadataBytes ||
        count * 32 + attrBytes + metaBytes + (classifications?.length ?? 0) >
            limits.maxDecodedBytes) {
      throw AssetLoadException(
        AssetLoadError.limitExceeded,
        'Point attributes or decoded payload exceed their budget.',
      );
    }
    return PointCloudData._(
      sourceUri,
      sourceVersion,
      Float64List.fromList(values),
      classifications == null ? null : Uint8List.fromList(classifications),
      Int64List.fromList(indices),
      attributes == null ? null : List.unmodifiable(attributes.map(_freezeMap)),
      _freezeMap(metadata),
      attrBytes,
      metaBytes,
    );
  }

  int get count => _positions.length ~/ 3;
  int get coordinateBytes => _positions.lengthInBytes;
  int get classificationBytes => _classifications?.lengthInBytes ?? 0;
  int get payloadBytes =>
      coordinateBytes +
      classificationBytes +
      _recordIndices.lengthInBytes +
      attributeBytes +
      metadataBytes;
  int? classificationAt(int index) {
    identityAt(index);
    return _classifications?[index] ??
        _attributes?[index]['classification'] as int?;
  }

  Map<String, Object?> attributesAt(int index) {
    identityAt(index);
    return _attributes?[index] ?? const {};
  }

  (Uri, String, int) identityAt(int index) {
    RangeError.checkValidIndex(index, _positions, 'index', count);
    return (sourceUri, sourceVersion, _recordIndices[index]);
  }

  Vec3 pointAt(int index) {
    identityAt(index);
    return Vec3(
      _positions[index * 3],
      _positions[index * 3 + 1],
      _positions[index * 3 + 2],
    );
  }

  /// A subset of original samples, never centroids or reconstructed measurements.
  PointCloudData select(
    Iterable<int> indices, {
    PointCloudLimits limits = const PointCloudLimits(),
  }) {
    final selected = indices.toList();
    return PointCloudData(
      sourceUri: sourceUri,
      sourceVersion: sourceVersion,
      points: selected.map(pointAt),
      recordIndices: selected.map((i) => identityAt(i).$3).toList(),
      classifications: _classifications == null
          ? null
          : selected.map((i) => _classifications[i]).toList(),
      attributes: _attributes == null
          ? null
          : selected.map(attributesAt).toList(),
      metadata: metadata,
      limits: limits,
    );
  }
}

Map<String, Object?> _freezeMap(Map<String, Object?> value) =>
    Map.unmodifiable(value.map((k, v) => MapEntry(k, _freeze(v))));
Object? _freeze(Object? value) => switch (value) {
  Map<String, Object?> value => _freezeMap(value),
  List value => List<Object?>.unmodifiable(value.map(_freeze)),
  _ => value,
};
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
