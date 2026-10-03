import 'layer.dart';
import 'selection.dart';

final class GeoLayerChange {
  final int previousRevision, revision;
  final List<GeoLayer> snapshot;
  final List<GeoFeatureId> selection;
  final Set<String> addedIds, removedIds, updatedIds;
  GeoLayerChange({
    required this.previousRevision,
    required this.revision,
    required Iterable<GeoLayer> snapshot,
    required Iterable<GeoFeatureId> selection,
    required Iterable<String> addedIds,
    required Iterable<String> removedIds,
    required Iterable<String> updatedIds,
  }) : snapshot = List.unmodifiable(snapshot),
       selection = List.unmodifiable(selection),
       addedIds = Set.unmodifiable(addedIds),
       removedIds = Set.unmodifiable(removedIds),
       updatedIds = Set.unmodifiable(updatedIds);
}
