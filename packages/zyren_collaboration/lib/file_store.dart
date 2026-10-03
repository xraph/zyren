/// Native file storage. Keep credentials outside these scene documents.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'src/durable_authority.dart';

/// Atomic replacement with a persistent sibling advisory lock. All writers must
/// use this adapter, with one owning isolate per process and a local filesystem.
/// Flushing the staged file protects process restarts. Directory fsync and power
/// loss guarantees depend on the host filesystem and are not provided here.
final class FileSceneDocumentStore implements SceneDocumentStore {
  static final _queues = <String, Future<void>>{};
  final File file;
  final int maxBytes;
  FileSceneDocumentStore(this.file, {this.maxBytes = 64 * 1024 * 1024}) {
    if (maxBytes < 1 || maxBytes > 128 * 1024 * 1024) {
      throw ArgumentError('Invalid document limit.');
    }
  }
  @override
  Future<T> transact<T>(Future<(T, String?)> Function(String?) action) async {
    await file.parent.create(recursive: true);
    final key =
        '${await file.parent.resolveSymbolicLinks()}/${file.uri.pathSegments.last}';
    final previous = _queues[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _queues[key] = gate.future;
    RandomAccessFile? handle;
    var locked = false;
    try {
      await previous;
      handle = await File('$key.lock').open(mode: FileMode.append);
      await handle.lock(FileLock.blockingExclusive);
      locked = true;
      String? current;
      try {
        if (await file.length() > maxBytes) {
          throw const FormatException('Scene file too large.');
        }
        current = await file.readAsString();
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 2) rethrow;
      }
      final (result, replacement) = await action(current);
      if (replacement != null && replacement != current) {
        final bytes = utf8.encode(replacement);
        if (bytes.length > maxBytes) {
          throw StateError('Scene file exceeds capacity.');
        }
        final staging = await file.parent.createTemp('.scene-');
        try {
          final next = File('${staging.path}/document');
          await next.writeAsBytes(bytes, flush: true);
          await next.rename(file.path);
        } finally {
          await staging.delete(recursive: true);
        }
      }
      return result;
    } finally {
      try {
        if (locked) await handle!.unlock();
      } finally {
        try {
          await handle?.close();
        } finally {
          gate.complete();
          if (identical(_queues[key], gate.future)) _queues.remove(key);
        }
      }
    }
  }
}
