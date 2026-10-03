import '../rendering/scene_issue.dart';
import 'asset_scope.dart';
import 'source_resolver.dart';

/// A typed source and decoder. [version] separates in-flight work for explicit
/// content revisions. Scopes cache completed recipes only when you supply a cache.
final class AssetRequest<T extends Object> {
  final Uri uri;
  final AssetLoader<T> loader;
  final String? version;
  AssetRequest({required this.uri, required this.loader, this.version}) {
    if (!uri.hasScheme || uri.hasFragment) {
      throw ArgumentError.value(
        uri,
        'uri',
        'Use an absolute source URI without a fragment.',
      );
    }
  }
  @override
  bool operator ==(Object other) =>
      other is AssetRequest<T> &&
      runtimeType == other.runtimeType &&
      uri == other.uri &&
      version == other.version &&
      loader.runtimeType == other.loader.runtimeType &&
      loader.cacheKey == other.loader.cacheKey;
  @override
  int get hashCode =>
      Object.hash(T, uri, version, loader.runtimeType, loader.cacheKey);
}

/// Optional format decoders depend only on core CPU services.
abstract class AssetLoader<T extends Object> {
  const AssetLoader();

  /// An immutable value including every decode option. The default shares only
  /// this loader instance; equal keys also need equal loader and result types.
  Object get cacheKey => this;
  Future<DecodedAsset<T>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  );
}

/// One decoded job with a fresh scope-owned result for each live consumer.
/// [create] retains shared data for that result. [dispose] drops the job's own
/// hold, including when cancellation makes its result arrive too late.
final class DecodedAsset<T extends Object> {
  final T Function() create;
  final void Function(T) release;
  final void Function()? dispose;

  /// Recipe storage size. Null uses the decode context accounting.
  final int? decodedBytes;
  const DecodedAsset({
    required this.create,
    required this.release,
    this.dispose,
    this.decodedBytes,
  });

  /// Releases a delivered result, including when a request widens its type.
  void releaseValue(T value) => release(value);
}

enum AssetLoadError {
  sourceUnavailable,
  sourceFailed,
  limitExceeded,
  forbiddenReference,
  invalidData,
  unsupportedFeature,
  decodeFailed,
}

final class AssetLoadException extends SceneException {
  final AssetLoadError code;
  final String? fieldPath;

  /// Transport status, when the failure originated from an HTTP response.
  final int? httpStatus;
  AssetLoadException(
    this.code,
    String message, {
    Uri? sourceUri,
    this.fieldPath,
    this.httpStatus,
    Object? cause,
  }) : super(
         SceneIssue(
           code: 'asset.${code.name}',
           message: message,
           operation: 'load',
           sourceUri: sourceUri,
           resourceLabel: fieldPath,
           cause: cause,
         ),
       );
}
