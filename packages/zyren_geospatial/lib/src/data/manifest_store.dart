import '../layers/document.dart';
import 'store.dart';

final class GeoStoredManifest {
  final int revision;
  final Map<String, Object?> document;
  final Set<String> digests;
  GeoStoredManifest({
    required this.revision,
    required Map<String, Object?> document,
    required Set<String> digests,
  }) : document = copyLayerDocument(document, maxBytes: 4 * 1024 * 1024),
       digests = Set.unmodifiable(digests);
}

/// Pins and metadata publish in one transaction. A null expectedRevision means
/// the record must not exist. Removed records also require their exact revision.
abstract interface class GeoManifestStore implements GeoDataStore {
  Future<GeoStoredManifest?> readManifest(String id);
  Future<GeoStoredManifest> commitManifest(
    String id,
    Map<String, Object?> document,
    Set<String> digests, {
    required int? expectedRevision,
    Map<String, int> removeManifests = const {},
  });
}
