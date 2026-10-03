import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_pipeline/io.dart';

/// A read-only application bridge. Model archives and their dependency pins
/// remain owned by FilePipelineCache, outside geographic region transactions.
final class GeoModelBundleStore implements GeoBoundedDataStore {
  final FilePipelineCache cache;
  final String version, authorizationPartition;
  final DateTime publishedAt;
  late final GeoResourceKey key = GeoResourceKey(
    sourceId: 'planet-models',
    sourceVersion: version,
    authorizationPartition: authorizationPartition,
    address: 'bundle',
    representation: 'zybundle',
    decoderVersion: 1,
  );
  final _operations = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;
  GeoModelBundleStore({
    required this.cache,
    required this.version,
    required this.authorizationPartition,
    required this.publishedAt,
  }) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(version) || !publishedAt.isUtc) {
      throw ArgumentError(
        'Model references need a verified bundle version and a recorded UTC publication time.',
      );
    }
    key;
  }
  @override
  Future<GeoResource?> read(GeoResourceKey key) =>
      readBounded(key, maxBytes: cache.limits.maxArchiveBytes);
  @override
  Future<GeoResource?> readBounded(
    GeoResourceKey requested, {
    required int maxBytes,
  }) {
    if (_operations.length >= 128) {
      return Future.error(const GeoDataException(GeoDataError.budgetExceeded));
    }
    final result = Future<GeoResource?>.sync(() async {
      if (_closed) throw const GeoDataException(GeoDataError.closed);
      if (requested.authorizationPartition != authorizationPartition) {
        throw const GeoDataException(GeoDataError.denied);
      }
      if (requested != key) return null;
      try {
        final entry = (await cache.inspect())
            .where((e) => e.version == version)
            .firstOrNull;
        if (entry == null) return null;
        if (maxBytes < 1 || entry.archiveBytes > maxBytes) {
          throw const GeoDataException(GeoDataError.budgetExceeded);
        }
        final bundle = await cache.get(version);
        if (_closed) throw const GeoDataException(GeoDataError.closed);
        if (bundle == null) return null;
        if (bundle.version != version) {
          throw const GeoDataException(GeoDataError.corrupt);
        }
        final bytes = bundle.encode(limits: cache.limits);
        if (bytes.length > maxBytes) {
          throw const GeoDataException(GeoDataError.budgetExceeded);
        }
        return GeoResource(
          key: key,
          bytes: bytes,
          fetchedAt: publishedAt,
          checksum: sha256.convert(bytes).toString(),
          mediaType: 'application/x-zyren-bundle',
          mayPersist: false,
        );
      } on FileSystemException catch (error) {
        throw GeoDataException(GeoDataError.invalidResponse, cause: error);
      } on PipelineCacheCorruption catch (error) {
        throw GeoDataException(GeoDataError.corrupt, cause: error);
      }
    });
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _operations.add(settled);
    unawaited(settled.then((_) => _operations.remove(settled)));
    return result;
  }

  @override
  Future<bool> write(GeoResource resource) =>
      Future.error(const GeoDataException(GeoDataError.denied));
  @override
  Future<void> remove(GeoResourceKey key) =>
      Future.error(const GeoDataException(GeoDataError.denied));
  @override
  Future<void> close() {
    _closed = true;
    return _closing ??= _drain();
  }

  Future<void> _drain() async {
    while (_operations.isNotEmpty) {
      await Future.wait(_operations.toList());
    }
  }
}
