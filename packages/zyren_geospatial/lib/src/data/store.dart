import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'resource_key.dart';
import 'policy.dart';

final class GeoResource {
  final GeoResourceKey key;
  final Uint8List bytes;
  final DateTime fetchedAt;
  final String checksum;
  final DateTime? expiresAt;
  final String? mediaType;
  final bool mayPersist;
  GeoResource({
    required this.key,
    required Uint8List bytes,
    required this.fetchedAt,
    required this.checksum,
    this.expiresAt,
    this.mediaType,
    this.mayPersist = true,
  }) : bytes = _copy(bytes) {
    if (!fetchedAt.isUtc ||
        (expiresAt != null && !expiresAt!.isUtc) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(checksum) ||
        (mediaType != null &&
            (mediaType!.length > 256 ||
                mediaType!.contains(RegExp(r'[\r\n]'))))) {
      throw ArgumentError(
        'Resource metadata needs UTC times, a SHA-256 digest and bounded media type.',
      );
    }
  }
  static Uint8List _copy(Uint8List bytes) {
    if (bytes.length > 512 * 1024 * 1024) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  void verify() {
    if (sha256.convert(bytes).toString() != checksum) {
      throw const GeoDataException(GeoDataError.corrupt);
    }
  }

  bool isFreshAt(DateTime now, {Duration? maxAge}) =>
      (expiresAt == null || now.isBefore(expiresAt!)) &&
      (maxAge == null || now.difference(fetchedAt) <= maxAge);
}

abstract interface class GeoDataStore {
  Future<GeoResource?> read(GeoResourceKey key);
  Future<bool> write(GeoResource resource);
  Future<void> remove(GeoResourceKey key);
  Future<void> close();
}

/// Optional bounded-read capability for callers with smaller per-read budgets.
abstract interface class GeoBoundedDataStore implements GeoDataStore {
  Future<GeoResource?> readBounded(GeoResourceKey key, {required int maxBytes});
}

/// Payload bytes and entry count are separate bounds. Keys have their own limits.
final class MemoryGeoDataStore implements GeoBoundedDataStore {
  final int maxBytes, maxEntries;
  final _entries = <GeoResourceKey, GeoResource>{};
  int _bytes = 0;
  bool _closed = false;
  MemoryGeoDataStore({required this.maxBytes, required this.maxEntries}) {
    if (maxBytes < 0 || maxEntries < 0) {
      throw ArgumentError('Store budgets cannot be negative.');
    }
  }
  int get usedBytes => _bytes;
  int get entryCount => _entries.length;
  void _check() {
    if (_closed) throw const GeoDataException(GeoDataError.closed);
  }

  @override
  Future<GeoResource?> read(GeoResourceKey key) async {
    _check();
    final value = _entries.remove(key);
    if (value != null) {
      value.verify();
      _entries[key] = value;
    }
    return value;
  }

  @override
  Future<GeoResource?> readBounded(
    GeoResourceKey key, {
    required int maxBytes,
  }) async {
    _check();
    if (maxBytes < 1 || (_entries[key]?.bytes.length ?? 0) > maxBytes) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    return read(key);
  }

  @override
  Future<bool> write(GeoResource resource) async {
    _check();
    resource.verify();
    if (!resource.mayPersist) throw const GeoDataException(GeoDataError.denied);
    if (resource.bytes.length > maxBytes || maxEntries == 0) return false;
    final old = _entries.remove(resource.key);
    _bytes -= old?.bytes.length ?? 0;
    while (_entries.isNotEmpty &&
        (_entries.length >= maxEntries ||
            _bytes + resource.bytes.length > maxBytes)) {
      final removed = _entries.remove(_entries.keys.first)!;
      _bytes -= removed.bytes.length;
    }
    _entries[resource.key] = resource;
    _bytes += resource.bytes.length;
    return true;
  }

  @override
  Future<void> remove(GeoResourceKey key) async {
    _check();
    _bytes -= _entries.remove(key)?.bytes.length ?? 0;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _entries.clear();
    _bytes = 0;
  }
}
