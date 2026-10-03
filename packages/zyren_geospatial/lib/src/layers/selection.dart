import '../geodesy.dart';

final class GeoFeatureId {
  final String layerId, featureId;
  const GeoFeatureId(this.layerId, this.featureId);
  @override
  bool operator ==(Object other) =>
      other is GeoFeatureId &&
      layerId == other.layerId &&
      featureId == other.featureId;
  @override
  int get hashCode => Object.hash(layerId, featureId);
}

final class GeoFeatureHit {
  final String layerId, featureId, sourceRevision;
  final Geodetic position;
  final Object? metadata;
  const GeoFeatureHit({
    required this.layerId,
    required this.featureId,
    required this.position,
    required this.sourceRevision,
    this.metadata,
  });
  GeoFeatureId get identity => GeoFeatureId(layerId, featureId);
}

/// Selection contains stable IDs, without renderer objects or mesh handles.
final class GeoSelection {
  final List<GeoFeatureId> snapshot;
  GeoSelection(Iterable<GeoFeatureId> values)
    : snapshot = List.unmodifiable(values);
}
