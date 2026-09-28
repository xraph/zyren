part of 'asset_scope.dart';

/// CPU-only services. Reuse one instance across scopes to share in-flight jobs.
final class AssetServices {
  final ByteSourceResolver resolver;
  final ImageDecoder? imageDecoder;
  final HdrImageDecoder? hdrImageDecoder;
  final TangentGenerator? tangentGenerator;
  final AssetLimits limits;
  final SourcePolicy policy;

  /// Receives cleanup errors that arrive after all consumers have cancelled.
  /// Reporting must not throw or retain decoded resources.
  final void Function(Object error)? onCleanupError;
  const AssetServices({
    this.resolver = const UnavailableSourceResolver(),
    this.imageDecoder,
    this.hdrImageDecoder,
    this.tangentGenerator,
    this.limits = const AssetLimits(),
    this.policy = const SourcePolicy(),
    this.onCleanupError,
  });

  static final _pools = Expando<_SharedLoadPool>();
  _SharedLoadPool get _pool => _pools[this] ??= _SharedLoadPool(this);
}

/// Aggregate encoded/decoded payload limits for a job, not a process-memory cap.
final class AssetLimits {
  final int maxSourceBytes, maxTotalSourceBytes, maxSources, maxDecodedBytes;
  final ImageDecodeLimits images;
  final TangentGenerationLimits tangents;
  const AssetLimits({
    this.maxSourceBytes = 32 * 1024 * 1024,
    this.maxTotalSourceBytes = 128 * 1024 * 1024,
    this.maxSources = 128,
    this.maxDecodedBytes = 128 * 1024 * 1024,
    this.images = const ImageDecodeLimits(),
    this.tangents = const TangentGenerationLimits(),
  });
  void validate() {
    for (final (name, value) in [
      ('maxSourceBytes', maxSourceBytes),
      ('maxTotalSourceBytes', maxTotalSourceBytes),
      ('maxSources', maxSources),
      ('maxDecodedBytes', maxDecodedBytes),
    ]) {
      RangeError.checkValueInInterval(value, 1, 0x7fffffff, name);
    }
    images.validate();
    tangents.validate();
  }
}
