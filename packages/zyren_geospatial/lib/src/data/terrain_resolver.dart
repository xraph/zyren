import 'package:zyren/zyren.dart';
import 'policy.dart';
import 'resolver.dart';
import 'resource_key.dart';

/// Adapts logical source addresses to governed resources for existing terrain,
/// imagery and nested asset loaders. Construct a fresh source when changing its
/// policy so decoded content from an old source cannot stand in for an offline read.
final class GeoTerrainResourceResolver implements ByteSourceResolver {
  final GeoResourceResolver resources;
  final GeoReadPolicy policy;
  final Uri baseUri;
  final GeoResourceKey Function(Uri logicalUri) keyForUri;
  final String authorizationPartition;
  final Map<String, String> sourceVersions;
  GeoTerrainResourceResolver({
    required this.resources,
    required this.policy,
    required this.baseUri,
    required this.keyForUri,
    required this.authorizationPartition,
    required Map<String, String> sourceVersions,
  }) : sourceVersions = Map.unmodifiable(sourceVersions) {
    if (baseUri.scheme != 'geo-resource' ||
        baseUri.host.isEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        baseUri.userInfo.isNotEmpty ||
        !baseUri.path.endsWith('/') ||
        sourceVersions.isEmpty ||
        sourceVersions.length > 64) {
      throw ArgumentError(
        'Use a logical geo-resource base and pinned source versions.',
      );
    }
  }
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    try {
      const SourcePolicy().validate(baseUri, uri);
      if (!uri.path.startsWith(baseUri.path)) {
        throw const GeoDataException(GeoDataError.denied);
      }
      final key = keyForUri(uri);
      if (key.authorizationPartition != authorizationPartition ||
          sourceVersions[key.sourceId] != key.sourceVersion) {
        throw const GeoDataException(GeoDataError.denied);
      }
      final value = await resources.read(
        key,
        policy,
        cancellation: context.cancellation,
        maxBytes: context.maxBytes,
      );
      context.reportProgress(value.bytes.length, value.bytes.length);
      return ResolvedSource(
        effectiveUri: uri,
        bytes: value.bytes,
        mediaType: value.mediaType,
      );
    } on GeoDataException {
      rethrow;
    } on LoadCancelled {
      rethrow;
    } on AssetLoadException catch (e) {
      throw GeoDataException(
        e.code == AssetLoadError.limitExceeded
            ? GeoDataError.budgetExceeded
            : GeoDataError.denied,
        cause: e,
      );
    } catch (e) {
      throw GeoDataException(GeoDataError.invalidResponse, cause: e);
    }
  }
}
