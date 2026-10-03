import 'dart:async';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'policy.dart';
import 'resource_key.dart';
import 'store.dart';

/// Transport-only credentials and location. These never enter a resource key.
final class GeoTransportLocation {
  final Uri uri;
  final Map<String, String> headers;
  final SourcePolicy policy;
  final Duration? maxAge;
  GeoTransportLocation({
    required this.uri,
    Map<String, String> headers = const {},
    this.policy = const SourcePolicy(),
    this.maxAge,
  }) : headers = Map.unmodifiable(headers) {
    if (!uri.isAbsolute ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.toString().length > 16384 ||
        headers.length > 64 ||
        headers.entries.any(
          (e) =>
              e.key.length > 256 ||
              e.value.length > 8192 ||
              e.key.contains(RegExp(r'[\r\n]')) ||
              e.value.contains(RegExp(r'[\r\n]')),
        ) ||
        (maxAge?.isNegative ?? false)) {
      throw ArgumentError('Invalid geographic transport location.');
    }
  }
  @override
  String toString() => 'GeoTransportLocation(<transport only>)';
}

/// Reuses the application's bounded native source resolver.
/// The source must enforce maxBytes while streaming, not after allocation.
final class GeoByteSourceTransport {
  final ByteSourceResolver source;
  final FutureOr<GeoTransportLocation> Function(GeoResourceKey) locate;
  final int maxBytes;
  final DateTime Function() now;
  GeoByteSourceTransport({
    required this.source,
    required this.locate,
    this.maxBytes = 16 * 1024 * 1024,
    DateTime Function()? now,
  }) : now = now ?? _now {
    if (maxBytes < 1 || maxBytes > 512 * 1024 * 1024) {
      throw ArgumentError('Transport requires a bounded positive byte limit.');
    }
  }
  static DateTime _now() => DateTime.now().toUtc();
  Future<GeoResource> fetch(
    GeoResourceKey key,
    LoadCancellation cancellation,
  ) => fetchBounded(key, cancellation, maxBytes);

  Future<GeoResource> fetchBounded(
    GeoResourceKey key,
    LoadCancellation cancellation,
    int requestedBytes,
  ) async {
    final limit = math.min(maxBytes, requestedBytes);
    if (limit < 1) throw const GeoDataException(GeoDataError.budgetExceeded);
    try {
      cancellation.throwIfCancelled();
      final location = await locate(key);
      cancellation.throwIfCancelled();
      location.policy.validate(location.uri, location.uri);
      final started = now();
      final result = await source.read(
        location.uri,
        SourceReadContext(
          maxBytes: limit,
          cancellation: cancellation,
          policy: location.policy,
          headers: location.headers,
          onProgress: (_, _) {},
        ),
      );
      cancellation.throwIfCancelled();
      location.policy.validate(location.uri, result.effectiveUri);
      if (result.bytes.length > limit) {
        throw const GeoDataException(GeoDataError.budgetExceeded);
      }
      final received = now();
      final retention = _Retention(
        result.headers,
        started,
        received,
        location.maxAge,
        key.authorizationPartition != 'public',
      );
      return GeoResource(
        key: key,
        bytes: result.bytes,
        fetchedAt: received,
        checksum: sha256.convert(result.bytes).toString(),
        mediaType: result.mediaType,
        expiresAt: retention.expires,
        mayPersist: retention.allowed,
      );
    } on LoadCancelled {
      throw const GeoDataException(GeoDataError.cancelled);
    } on GeoDataException {
      rethrow;
    } on AssetLoadException catch (e) {
      final status = e.httpStatus;
      final code = switch (e.code) {
        AssetLoadError.limitExceeded => GeoDataError.budgetExceeded,
        AssetLoadError.forbiddenReference => GeoDataError.denied,
        AssetLoadError.sourceFailed
            when [401, 403, 407, 451].contains(status) =>
          GeoDataError.denied,
        AssetLoadError.sourceFailed
            when status == null ||
                status == 408 ||
                status == 429 ||
                (status >= 500 && status <= 599) =>
          GeoDataError.transportFailure,
        _ => GeoDataError.invalidResponse,
      };
      throw GeoDataException(code, cause: e);
    } catch (e) {
      throw GeoDataException(GeoDataError.invalidResponse, cause: e);
    }
  }
}

// Conservative HTTP retention, not a validator/304 implementation. Responses
// requiring validation or unspecified Vary dimensions are never retained.
final class _Retention {
  bool allowed = true;
  DateTime? expires;
  _Retention(
    Map<String, String> headers,
    DateTime started,
    DateTime received,
    Duration? maxAge,
    bool protectedPartition,
  ) {
    if (maxAge != null) expires = started.add(maxAge);
    final control = headers['cache-control'] ?? '';
    if (control.length > 8192 || (headers['vary']?.isNotEmpty ?? false)) {
      allowed = false;
      return;
    }
    final directives = control
        .toLowerCase()
        .split(',')
        .map((s) => s.trim())
        .toList();
    for (final directive in directives) {
      final name = directive.split('=').first.trim();
      if ([
            'no-store',
            'no-cache',
            'must-revalidate',
            'proxy-revalidate',
            'must-understand',
            's-maxage',
          ].contains(name) ||
          (name == 'private' && !protectedPartition)) {
        allowed = false;
      }
    }
    final ages = directives
        .where((s) => s.split('=').first.trim() == 'max-age')
        .toList();
    DateTime? deadline;
    if (ages.isNotEmpty) {
      final parts = ages.first.split('=');
      final seconds = parts.length == 2
          ? int.tryParse(parts[1].trim().replaceAll('"', ''))
          : null;
      final age = int.tryParse(headers['age'] ?? '0');
      final date = _httpDate(headers['date']);
      if (ages.length != 1 ||
          seconds == null ||
          seconds < 0 ||
          seconds > 315360000 ||
          age == null ||
          age < 0 ||
          (headers.containsKey('date') && date == null)) {
        allowed = false;
      } else {
        final apparentAge = date == null
            ? Duration.zero
            : received.difference(date);
        final correctedAge =
            Duration(seconds: age) + received.difference(started);
        final spent = math.max(
          0,
          math.max(apparentAge.inMicroseconds, correctedAge.inMicroseconds),
        );
        deadline = received.add(
          Duration(microseconds: math.max(0, seconds * 1000000 - spent)),
        );
      }
    } else if (headers.containsKey('expires')) {
      deadline = _httpDate(headers['expires']);
      if (deadline == null) allowed = false;
    }
    if (deadline != null && (expires == null || deadline.isBefore(expires!))) {
      expires = deadline;
    }
  }
}

DateTime? _httpDate(String? value) {
  if (value == null || value.length > 64) return null;
  final match = RegExp(
    r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value);
  if (match == null) return null;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months.indexOf(match[2]!) + 1;
  final day = int.parse(match[1]!), year = int.parse(match[3]!);
  final hour = int.parse(match[4]!),
      minute = int.parse(match[5]!),
      second = int.parse(match[6]!);
  if (month == 0 ||
      day < 1 ||
      day > 31 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  final date = DateTime.utc(year, month, day, hour, minute, second);
  return date.day == day && date.month == month ? date : null;
}
