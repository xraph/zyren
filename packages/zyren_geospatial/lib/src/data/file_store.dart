import 'dart:async';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'file_index.dart';
import 'file_lock.dart';
import 'integrity.dart';
import 'policy.dart';
import 'resource_key.dart';
import 'store.dart';

final class GeoStoreStats {
  final int entries, committedBytes, metadataBytes, temporaryBytes, pinnedBytes;

  /// Reads return owned byte copies, so the store exposes no leased disk handles.
  final int leasedBytes;
  final int manifests;
  const GeoStoreStats({
    required this.entries,
    required this.committedBytes,
    required this.metadataBytes,
    required this.temporaryBytes,
    required this.pinnedBytes,
    required this.manifests,
    this.leasedBytes = 0,
  });
  int get totalBytes => committedBytes + metadataBytes + temporaryBytes;
}

enum GeoStoreWriteStage {
  payloadStaged,
  payloadPublished,
  indexStaged,
  indexCommitted,
}

/// Uses a private directory, immutable digest-named blobs and a checksummed
/// index journal. maxBytes covers payloads, metadata and transactional staging.
final class FileGeoDataStore implements GeoDataStore {
  final Directory directory;
  final int maxBytes, maxEntries, maxManifests, maxIndexBytes;
  final Duration lockTimeout;

  /// Optional fault injection or write instrumentation. Throwing aborts the write
  /// before the next stage; indexCommitted already made the operation durable.
  final FutureOr<void> Function(GeoStoreWriteStage)? onWriteStage;
  late final _lock = GeoFileLock(directory, lockTimeout);
  Future<void> _tail = Future.value();
  Future<void>? _closeFuture;
  int _pending = 0;
  bool _closed = false;
  FileGeoDataStore({
    required this.directory,
    required this.maxBytes,
    required this.maxEntries,
    this.maxManifests = 256,
    this.maxIndexBytes = 16 * 1024 * 1024,
    this.lockTimeout = const Duration(seconds: 10),
    this.onWriteStage,
  }) {
    if (maxBytes < 1024 ||
        maxBytes > 1 << 50 ||
        maxEntries < 1 ||
        maxEntries > 100000 ||
        maxManifests < 1 ||
        maxManifests > 10000 ||
        maxIndexBytes < 256 ||
        maxIndexBytes > 64 * 1024 * 1024 ||
        lockTimeout <= Duration.zero ||
        lockTimeout > const Duration(minutes: 1)) {
      throw ArgumentError('Invalid geographic disk store limits.');
    }
  }

  Future<T> _operation<T>(
    Future<T> Function(Directory, LoadCancellation) action,
    LoadCancellation? cancellation,
  ) {
    if (_closed) {
      return Future.error(const GeoDataException(GeoDataError.closed));
    }
    if (_pending >= 1024) {
      return Future.error(const GeoDataException(GeoDataError.budgetExceeded));
    }
    _pending++;
    final token = cancellation ?? LoadCancellationSource();
    final result = _tail.then((_) async {
      try {
        return await _lock.run(action, token);
      } on LoadCancelled {
        throw const GeoDataException(GeoDataError.cancelled);
      } on GeoDataException {
        rethrow;
      } catch (e) {
        throw GeoDataException(GeoDataError.transportFailure, cause: e);
      }
    });
    _tail = result.then<void>(
      (_) {
        _pending--;
      },
      onError: (Object _, StackTrace _) {
        _pending--;
      },
    );
    return result;
  }

  Future<GeoFileIndex> _recover(Directory root, LoadCancellation token) async {
    final indexFile = File('${root.path}/index.json');
    await regularFileOrAbsent(indexFile);
    final index = await indexFile.exists()
        ? GeoFileIndex.decode(
            await readGeoFile(indexFile, maxIndexBytes, token),
            maxEntries: 100000,
            maxManifests: 10000,
          )
        : GeoFileIndex();
    final retained = index.entries.values.map((e) => e.filename).toSet();
    var count = 0;
    await for (final entity in root.list(followLinks: false)) {
      token.throwIfCancelled();
      if (++count > 210000) {
        throw const GeoDataException(GeoDataError.budgetExceeded);
      }
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final blob = RegExp(r'^[a-f0-9]{64}-[a-f0-9]{64}\.blob$').hasMatch(name);
      final temporary =
          name == 'index.pending.tmp' ||
          RegExp(r'^\.[a-f0-9]{64}-[a-f0-9]{64}\.tmp$').hasMatch(name);
      final known =
          blob ||
          temporary ||
          name == 'index.json' ||
          name == '.geo.lock' ||
          RegExp(r'^\.geo-gate-[0-9]+$').hasMatch(name);
      if (!known || entity is! File) {
        throw const GeoDataException(GeoDataError.denied);
      }
      if (temporary || (blob && !retained.contains(name))) {
        await entity.delete();
      }
    }
    return index;
  }

  Future<int> _metadataBytes(Directory root) async {
    final file = File('${root.path}/index.json');
    return await file.exists() ? file.length() : 0;
  }

  File _blob(Directory root, GeoFileEntry entry) =>
      File('${root.path}/${entry.filename}');
  Future<GeoResource> _readEntry(
    Directory root,
    GeoFileEntry entry,
    LoadCancellation token,
  ) async {
    final file = _blob(root, entry);
    await regularFileOrAbsent(file);
    if (!await file.exists() || await file.length() != entry.size) {
      throw const GeoDataException(GeoDataError.corrupt);
    }
    if (entry.size > maxBytes) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    final value = entry.resource(await readGeoFile(file, entry.size, token));
    value.verify();
    return value;
  }

  @override
  Future<GeoResource?> read(
    GeoResourceKey key, {
    LoadCancellation? cancellation,
  }) => _operation((root, token) async {
    final index = await _recover(root, token);
    final entry = index.entries[key.digest];
    if (entry == null) return null;
    final value = await _readEntry(root, entry, token);
    await _blob(root, entry).setLastModified(DateTime.now().toUtc());
    return value;
  }, cancellation);

  @override
  Future<bool> write(
    GeoResource resource, {
    LoadCancellation? cancellation,
  }) => _operation((root, token) async {
    resource.verify();
    if (!resource.mayPersist) throw const GeoDataException(GeoDataError.denied);
    var current = await _recover(root, token);
    final entry = GeoFileEntry(resource), digest = resource.key.digest;
    final old = current.entries[digest];
    if (current.pinned.contains(digest) && old!.checksum != entry.checksum) {
      return false;
    }
    final target = current.copy()..entries[digest] = entry;
    final reduced = current.copy();
    final victims = <String>[];
    final candidates = current.entries.values
        .where(
          (e) =>
              e.key.digest != digest && !current.pinned.contains(e.key.digest),
        )
        .toList();
    final modified = <String, DateTime>{};
    for (final candidate in candidates) {
      final file = _blob(root, candidate);
      await regularFileOrAbsent(file);
      modified[candidate.key.digest] = (await file.stat()).modified;
    }
    candidates.sort((a, b) {
      final order = modified[a.key.digest]!.compareTo(modified[b.key.digest]!);
      return order == 0 ? a.key.digest.compareTo(b.key.digest) : order;
    });
    final newPayload = old?.checksum == entry.checksum ? 0 : entry.size;
    bool admitted() {
      final targetBytes = target.encode().length;
      final reducedBytes = victims.isEmpty ? null : reduced.encode().length;
      final currentMetadata = reducedBytes ?? current.encode().length;
      return target.entries.length <= maxEntries &&
          target.pins.length <= maxManifests &&
          targetBytes <= maxIndexBytes &&
          reduced.payloadBytes + currentMetadata + newPayload + targetBytes <=
              maxBytes &&
          target.payloadBytes + 2 * targetBytes <= maxBytes;
    }

    while (!admitted() && candidates.isNotEmpty) {
      final victim = candidates.removeAt(0).key.digest;
      victims.add(victim);
      reduced.entries.remove(victim);
      target.entries.remove(victim);
    }
    if (!admitted()) return false;
    if (victims.isNotEmpty) {
      // Evict only unpinned cache entries before staging. The extra index reserve
      // keeps this transaction possible even when the payload budget is full.
      await _publish(root, current, reduced, token);
      current = reduced;
    }
    final file = _blob(root, entry);
    final staging = File('${root.path}/.$digest-${entry.checksum}.tmp');
    try {
      if (!await file.exists()) {
        token.throwIfCancelled();
        await regularFileOrAbsent(staging);
        await staging.writeAsBytes(resource.bytes, flush: true);
        await onWriteStage?.call(GeoStoreWriteStage.payloadStaged);
        token.throwIfCancelled();
        await regularFileOrAbsent(file);
        await staging.rename(file.path);
        await onWriteStage?.call(GeoStoreWriteStage.payloadPublished);
      } else {
        await _readEntry(root, entry, token);
      }
      await _publish(root, current, target, token, extraPayload: newPayload);
      return true;
    } finally {
      // Also recovers an orphan final blob after a failed publication.
      await _recover(root, LoadCancellationSource());
    }
  }, cancellation);

  Future<void> _publish(
    Directory root,
    GeoFileIndex previous,
    GeoFileIndex next,
    LoadCancellation token, {
    int extraPayload = 0,
  }) async {
    final bytes = next.encode();
    if (bytes.length > maxIndexBytes ||
        previous.payloadBytes +
                extraPayload +
                await _metadataBytes(root) +
                bytes.length >
            maxBytes ||
        next.payloadBytes + 2 * bytes.length > maxBytes) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    token.throwIfCancelled();
    final staging = File('${root.path}/index.pending.tmp');
    await regularFileOrAbsent(staging);
    await staging.writeAsBytes(bytes, flush: true);
    await onWriteStage?.call(GeoStoreWriteStage.indexStaged);
    token.throwIfCancelled();
    await regularFileOrAbsent(File('${root.path}/index.json'));
    await staging.rename('${root.path}/index.json');
    await onWriteStage?.call(GeoStoreWriteStage.indexCommitted);
    await _recover(root, LoadCancellationSource());
  }

  Future<void> pin(
    String manifestId,
    Set<String> digests, {
    LoadCancellation? cancellation,
  }) {
    validateGeoManifestId(manifestId);
    if (digests.length > maxEntries ||
        digests.any((d) => !geoDigestPattern.hasMatch(d))) {
      throw ArgumentError('Invalid offline pin set.');
    }
    final immutable = Set<String>.unmodifiable(digests);
    return _operation((root, token) async {
      final current = await _recover(root, token);
      if (!current.pins.containsKey(manifestId) &&
          current.pins.length >= maxManifests) {
        throw const GeoDataException(GeoDataError.budgetExceeded);
      }
      for (final digest in immutable) {
        final entry = current.entries[digest];
        if (entry == null) {
          throw const GeoDataException(GeoDataError.offlineMiss);
        }
        await _readEntry(root, entry, token);
      }
      final next = current.copy()..pins[manifestId] = immutable;
      try {
        await _publish(root, current, next, token);
      } finally {
        await _recover(root, LoadCancellationSource());
      }
    }, cancellation);
  }

  Future<void> unpin(String manifestId, {LoadCancellation? cancellation}) {
    validateGeoManifestId(manifestId);
    return _operation((root, token) async {
      final current = await _recover(root, token);
      if (!current.pins.containsKey(manifestId)) return;
      final next = current.copy()..pins.remove(manifestId);
      try {
        await _publish(root, current, next, token);
      } finally {
        await _recover(root, LoadCancellationSource());
      }
    }, cancellation);
  }

  @override
  Future<void> remove(GeoResourceKey key, {LoadCancellation? cancellation}) =>
      _operation((root, token) async {
        final current = await _recover(root, token);
        if (!current.entries.containsKey(key.digest)) return;
        if (current.pinned.contains(key.digest)) {
          throw const GeoDataException(GeoDataError.denied);
        }
        final next = current.copy()..entries.remove(key.digest);
        try {
          await _publish(root, current, next, token);
        } finally {
          await _recover(root, LoadCancellationSource());
        }
      }, cancellation);

  Future<GeoStoreStats> inspect({LoadCancellation? cancellation}) =>
      _operation((root, token) async {
        final current = await _recover(root, token);
        return GeoStoreStats(
          entries: current.entries.length,
          committedBytes: current.payloadBytes,
          metadataBytes: await _metadataBytes(root),
          temporaryBytes: 0,
          pinnedBytes: current.pinned.fold(
            0,
            (n, d) => n + current.entries[d]!.size,
          ),
          manifests: current.pins.length,
        );
      }, cancellation);

  @override
  Future<void> close() {
    _closed = true;
    return _closeFuture ??= _tail;
  }
}
