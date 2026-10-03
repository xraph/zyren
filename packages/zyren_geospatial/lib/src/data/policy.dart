import '../layers/document.dart';

enum GeoAccessMode { onlineOnly, cacheFirst, networkFirst, offlineOnly }

enum GeoDataError {
  offlineMiss,
  denied,
  corrupt,
  stale,
  cancelled,
  budgetExceeded,
  closed,
  transportFailure,
  invalidResponse,
  conflict,
}

final class GeoDataException implements Exception {
  final GeoDataError code;

  /// Retained for trusted diagnostics. Never included in the public message.
  final Object? cause;
  const GeoDataException(this.code, {this.cause});
  @override
  String toString() => 'Geographic data operation failed (${code.name}).';
}

final class GeoReadPolicy {
  final GeoAccessMode mode;
  final Duration? maxAge;
  final bool allowStaleOnTransportFailure, allowStaleOffline;
  final int maxAttempts;
  GeoReadPolicy({
    required this.mode,
    this.maxAge,
    this.allowStaleOnTransportFailure = false,
    this.allowStaleOffline = false,
    this.maxAttempts = 1,
  }) {
    if ((maxAge?.isNegative ?? false) || maxAttempts < 1 || maxAttempts > 4) {
      throw ArgumentError(
        'Read policies need a nonnegative age and one to four attempts.',
      );
    }
  }
  @override
  bool operator ==(Object other) =>
      other is GeoReadPolicy &&
      mode == other.mode &&
      maxAge == other.maxAge &&
      allowStaleOnTransportFailure == other.allowStaleOnTransportFailure &&
      maxAttempts == other.maxAttempts &&
      allowStaleOffline == other.allowStaleOffline;
  @override
  int get hashCode => Object.hash(
    mode,
    maxAge,
    allowStaleOnTransportFailure,
    allowStaleOffline,
    maxAttempts,
  );
}

/// Permissions are explicit. Missing metadata never permits persistence/export.
final class GeoSourceMetadata {
  final String sourceId, sourceVersion;
  final bool mayPersist, mayExportOffline;
  final List<String> credits;
  GeoSourceMetadata({
    required this.sourceId,
    required this.sourceVersion,
    this.mayPersist = false,
    this.mayExportOffline = false,
    List<String> credits = const [],
  }) : credits = List.unmodifiable(credits) {
    if (sourceId.isEmpty ||
        sourceVersion.isEmpty ||
        credits.length > 256 ||
        (mayExportOffline && !mayPersist)) {
      throw ArgumentError(
        'Offline export requires persistence permission and bounded metadata.',
      );
    }
    copyLayerDocument({
      'source': sourceId,
      'version': sourceVersion,
      'credits': credits,
    }, maxBytes: 32768);
  }
}
