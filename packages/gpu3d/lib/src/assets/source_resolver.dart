import 'dart:typed_data';
import 'asset_request.dart';
import 'load_cancellation.dart';

/// Reads at most [SourceReadContext.maxBytes], including unknown-length sources.
/// Implementations must check cancellation and redirects during the read.
abstract interface class ByteSourceResolver {
  Future<ResolvedSource> read(Uri uri, SourceReadContext context);
}

final class ResolvedSource {
  final Uri effectiveUri;
  final Uint8List bytes;
  final String? mediaType;
  ResolvedSource({
    required this.effectiveUri,
    required Uint8List bytes,
    this.mediaType,
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
}

final class SourceReadContext {
  final int maxBytes;
  final LoadCancellation cancellation;
  final SourcePolicy policy;
  final void Function(int received, int? total) _onProgress;
  SourceReadContext({
    required this.maxBytes,
    required this.cancellation,
    required this.policy,
    required void Function(int received, int? total) onProgress,
  }) : _onProgress = onProgress;

  void reportProgress(int received, [int? total]) {
    cancellation.throwIfCancelled();
    if (received < 0 || (total != null && (total < 0 || total < received))) {
      throw ArgumentError('Invalid source byte counts.');
    }
    if (received > maxBytes || (total != null && total > maxBytes)) {
      throw AssetLoadException(
        AssetLoadError.limitExceeded,
        'Source exceeds its byte budget.',
      );
    }
    _onProgress(received, total);
  }
}

/// Default references and redirects stay within the source's scheme and origin.
/// A host may supply a narrower or broader policy with its own resolver.
class SourcePolicy {
  const SourcePolicy();
  void validate(Uri from, Uri to, {String? fieldPath}) {
    if (!to.hasScheme ||
        to.hasFragment ||
        from.scheme != to.scheme ||
        from.host != to.host ||
        from.port != to.port ||
        to.userInfo.isNotEmpty) {
      throw AssetLoadException(
        AssetLoadError.forbiddenReference,
        'The source policy rejects this reference or redirect.',
        sourceUri: to,
        fieldPath: fieldPath,
      );
    }
  }
}

class UnavailableSourceResolver implements ByteSourceResolver {
  const UnavailableSourceResolver();
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) =>
      Future.error(
        AssetLoadException(
          AssetLoadError.sourceUnavailable,
          'No byte source resolver is configured for this scope.',
          sourceUri: uri,
        ),
      );
}
