import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:zyren/zyren.dart';
import 'bundle.dart';
import 'incremental.dart';

final class PipelineDiskEntry {
  final String version;
  final int archiveBytes;
  final bool pinned;
  final DateTime lastAccess;
  const PipelineDiskEntry(
    this.version,
    this.archiveBytes,
    this.pinned,
    this.lastAccess,
  );
}

final class PipelineCacheCorruption implements Exception {
  final String version;
  const PipelineCacheCorruption(this.version);
  @override
  String toString() => 'Corrupt cached bundle $version was removed.';
}

/// A dedicated cache directory with process locks, atomic publication, persistent
/// pins and an LRU archive-byte budget. Caller-held bundles are outside this budget.
final class FilePipelineCache {
  final Directory directory;
  final int maxBytes, maxBundles;
  final PipelineLimits limits;
  final Duration lockTimeout;
  final void Function(String event, String version)? onEvent;
  static final _tails = <String, Future<void>>{};
  final _random = Random.secure();
  FilePipelineCache({
    required this.directory,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxBundles = 64,
    this.limits = const PipelineLimits(),
    this.lockTimeout = const Duration(seconds: 10),
    this.onEvent,
  }) {
    if (maxBytes < 1 ||
        maxBundles < 1 ||
        maxBundles > 4096 ||
        lockTimeout <= Duration.zero) {
      throw ArgumentError('Invalid disk cache limits.');
    }
    limits.validate();
  }

  Future<List<PipelineDiskEntry>> inspect({LoadCancellation? cancellation}) =>
      _locked((token) async {
        await _recover(token);
        return List.unmodifiable(await _entries());
      }, cancellation);

  Future<bool> put(
    PipelineBundle bundle, {
    bool pin = false,
    LoadCancellation? cancellation,
  }) async {
    cancellation?.throwIfCancelled();
    final bytes = bundle.encode(limits: limits);
    if (bytes.length > maxBytes) return false;
    return _locked((token) async {
      await _recover(token);
      final entries = await _entries();
      final existing = entries
          .where((e) => e.version == bundle.version)
          .firstOrNull;
      final victims = <PipelineDiskEntry>[];
      var total =
          entries.fold<int>(0, (sum, e) => sum + e.archiveBytes) -
          (existing?.archiveBytes ?? 0) +
          bytes.length;
      var count = entries.length + (existing == null ? 1 : 0);
      for (final entry in entries) {
        if (total <= maxBytes && count <= maxBundles) break;
        if (entry.pinned || entry.version == bundle.version) continue;
        victims.add(entry);
        total -= entry.archiveBytes;
        count--;
      }
      if (total > maxBytes || count > maxBundles) return false;
      token.throwIfCancelled();
      final temporary = File(
        '${directory.path}/.pipeline-${_random.nextInt(0x7fffffff)}.tmp',
      );
      var published = false;
      final newPin = pin && !(existing?.pinned ?? false);
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        token.throwIfCancelled();
        // Publish the pin before the archive so interrupted eviction retains it.
        if (newPin) await _pin(bundle.version).writeAsString('', flush: true);
        await temporary.rename(_bundle(bundle.version).path);
        published = true;
        for (final victim in victims) {
          await _remove(victim.version);
          _event('evicted', victim.version);
        }
        _event('stored', bundle.version);
        return true;
      } finally {
        if (!published && newPin && await _pin(bundle.version).exists()) {
          await _pin(bundle.version).delete();
        }
        if (await temporary.exists()) await temporary.delete();
      }
    }, cancellation);
  }

  Future<PipelineBundle?> get(
    String version, {
    LoadCancellation? cancellation,
  }) {
    _version(version);
    return _locked((token) async {
      await _recover(token);
      final file = _bundle(version);
      if (!await file.exists()) return null;
      final bundle = await _decode(version, token);
      await file.setLastModified(DateTime.now().toUtc());
      _event('hit', version);
      return bundle;
    }, cancellation);
  }

  Future<bool> setPinned(
    String version,
    bool pinned, {
    LoadCancellation? cancellation,
  }) {
    _version(version);
    return _locked((token) async {
      // Unpinning must remain possible after a host reduces the cache budget.
      await _entries();
      if (!await _bundle(version).exists()) return false;
      token.throwIfCancelled();
      if (pinned) {
        await _pin(version).writeAsString('', flush: true);
      } else if (await _pin(version).exists()) {
        await _pin(version).delete();
      }
      await _recover(token);
      _event(pinned ? 'pinned' : 'unpinned', version);
      return true;
    }, cancellation);
  }

  /// Explicit invalidation also removes pins. A pin prevents budget eviction only.
  Future<bool> invalidateVersion(
    String version, {
    LoadCancellation? cancellation,
  }) {
    _version(version);
    return _locked((token) async {
      token.throwIfCancelled();
      if (!await _bundle(version).exists()) return false;
      await _remove(version);
      _event('invalidated', version);
      return true;
    }, cancellation);
  }

  Future<List<String>> invalidateSource(
    String sourceId, {
    LoadCancellation? cancellation,
  }) => _locked((token) async {
    await _recover(token);
    final removed = <String>[];
    for (final entry in await _entries()) {
      token.throwIfCancelled();
      PipelineBundle bundle;
      try {
        bundle = await _decode(entry.version, token);
      } on PipelineCacheCorruption {
        continue;
      }
      if (bundle.resources.any((r) => r.source.sourceId == sourceId)) {
        await _remove(entry.version);
        removed.add(entry.version);
        _event('invalidated', entry.version);
      }
    }
    return List.unmodifiable(removed);
  }, cancellation);

  Future<PipelineBundle> _decode(String version, LoadCancellation token) async {
    final file = _bundle(version);
    try {
      if (await file.length() > limits.maxArchiveBytes) {
        throw const FormatException('Archive budget exceeded.');
      }
      token.throwIfCancelled();
      final bytes = await file.readAsBytes();
      token.throwIfCancelled();
      final bundle = PipelineBundle.decode(bytes, limits: limits);
      if (bundle.version != version) {
        throw const FormatException('Cache filename differs from digest.');
      }
      return bundle;
    } on FormatException {
      await _remove(version);
      _event('corrupt', version);
      throw PipelineCacheCorruption(version);
    }
  }

  Future<void> _recover(LoadCancellation token) async {
    await for (final entity in directory.list(followLinks: false)) {
      token.throwIfCancelled();
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (entity is File &&
          RegExp(r'^[a-f0-9]{64}\.pin$').hasMatch(name) &&
          !await _bundle(name.substring(0, 64)).exists()) {
        await entity.delete();
        _event('recovered-pin', name.substring(0, 64));
      }
      if (entity is File &&
          RegExp(r'^\.pipeline-[0-9]+\.tmp$').hasMatch(name)) {
        await entity.delete();
        _event('recovered-temporary', name);
      }
    }
    final entries = await _entries();
    var bytes = entries.fold<int>(0, (sum, e) => sum + e.archiveBytes),
        count = entries.length;
    for (final entry in entries) {
      if (bytes <= maxBytes && count <= maxBundles) break;
      if (entry.pinned) continue;
      token.throwIfCancelled();
      await _remove(entry.version);
      bytes -= entry.archiveBytes;
      count--;
      _event('evicted', entry.version);
    }
    if (bytes > maxBytes || count > maxBundles) {
      throw StateError('Pinned archives exceed this cache budget.');
    }
  }

  Future<List<PipelineDiskEntry>> _entries() async {
    final entries = <PipelineDiskEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(r'^[a-f0-9]{64}\.zybundle$').hasMatch(name)) continue;
      if (entity is! File) {
        throw const FileSystemException(
          'Cache archive must be a regular file.',
        );
      }
      final stat = await entity.stat();
      final version = name.substring(0, 64);
      final pinType = await FileSystemEntity.type(
        _pin(version).path,
        followLinks: false,
      );
      if (pinType != FileSystemEntityType.notFound &&
          pinType != FileSystemEntityType.file) {
        throw const FileSystemException('Cache pin must be a regular file.');
      }
      entries.add(
        PipelineDiskEntry(
          version,
          stat.size,
          pinType == FileSystemEntityType.file,
          stat.modified,
        ),
      );
    }
    entries.sort((a, b) {
      final order = a.lastAccess.compareTo(b.lastAccess);
      return order == 0 ? a.version.compareTo(b.version) : order;
    });
    return entries;
  }

  Future<T> _locked<T>(
    Future<T> Function(LoadCancellation) action,
    LoadCancellation? cancellation,
  ) async {
    final token = cancellation ?? PipelineCancellation();
    token.throwIfCancelled();
    await directory.create(recursive: true);
    final key = await directory.resolveSymbolicLinks();
    final previous = _tails[key] ?? Future<void>.value();
    final completion = Completer<void>();
    _tails[key] = completion.future;
    try {
      await previous;
      token.throwIfCancelled();
      final file = File('$key/.pipeline.lock');
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw const FileSystemException('Invalid cache lock file.');
      }
      final handle = await file.open(mode: FileMode.append);
      var locked = false;
      try {
        final deadline = DateTime.now().add(lockTimeout);
        while (!locked) {
          token.throwIfCancelled();
          try {
            await handle.lock(FileLock.exclusive);
            locked = true;
          } on FileSystemException {
            if (DateTime.now().isAfter(deadline)) {
              throw TimeoutException('Disk cache lock timeout.', lockTimeout);
            }
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }
        token.throwIfCancelled();
        return await action(token);
      } finally {
        try {
          if (locked) await handle.unlock();
        } finally {
          await handle.close();
        }
      }
    } finally {
      completion.complete();
      if (identical(_tails[key], completion.future)) _tails.remove(key);
    }
  }

  File _bundle(String version) => File('${directory.path}/$version.zybundle');
  File _pin(String version) => File('${directory.path}/$version.pin');
  Future<void> _remove(String version) async {
    final file = _bundle(version), pin = _pin(version);
    if (await file.exists()) await file.delete();
    if (await pin.exists()) await pin.delete();
  }

  void _event(String event, String version) {
    try {
      onEvent?.call(event, version);
    } catch (_) {}
  }

  void _version(String version) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(version)) {
      throw ArgumentError('Invalid bundle version.');
    }
  }
}
