import 'dart:async';
import 'dart:io';
import 'package:zyren/zyren.dart';
import 'policy.dart';

/// Serializes local instances and uses OS locks between processes. The exclusive
/// PID gate also serializes isolates, since POSIX locks are process-scoped.
final class GeoFileLock {
  static final _tails = <String, Future<void>>{};
  final Directory directory;
  final Duration timeout;
  GeoFileLock(this.directory, this.timeout);

  Future<T> run<T>(
    Future<T> Function(Directory, LoadCancellation) action,
    LoadCancellation token,
  ) async {
    token.throwIfCancelled();
    final initial = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (initial != FileSystemEntityType.directory &&
        initial != FileSystemEntityType.notFound) {
      throw const GeoDataException(GeoDataError.denied);
    }
    await directory.create(recursive: true);
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const GeoDataException(GeoDataError.denied);
    }
    final root = Directory(await directory.resolveSymbolicLinks());
    final previous = _tails[root.path] ?? Future<void>.value();
    final finished = Completer<void>();
    _tails[root.path] = finished.future;
    try {
      await previous;
      token.throwIfCancelled();
      final deadline = DateTime.now().add(timeout);
      final gate = File('${root.path}/.geo-gate-$pid');
      var gated = false;
      RandomAccessFile? handle;
      var locked = false;
      try {
        while (!gated) {
          token.throwIfCancelled();
          await regularFileOrAbsent(gate);
          try {
            await gate.create(exclusive: true);
            gated = true;
          } on FileSystemException {
            if (DateTime.now().isAfter(deadline)) {
              throw const GeoDataException(GeoDataError.transportFailure);
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        final file = File('${root.path}/.geo.lock');
        await regularFileOrAbsent(file);
        handle = await file.open(mode: FileMode.append);
        while (!locked) {
          token.throwIfCancelled();
          try {
            await handle.lock(FileLock.exclusive);
            locked = true;
          } on FileSystemException {
            if (DateTime.now().isAfter(deadline)) {
              throw const GeoDataException(GeoDataError.transportFailure);
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        }
        token.throwIfCancelled();
        if (await FileSystemEntity.type(directory.path, followLinks: false) !=
                FileSystemEntityType.directory ||
            await directory.resolveSymbolicLinks() != root.path) {
          throw const GeoDataException(GeoDataError.denied);
        }
        return await action(root, token);
      } finally {
        try {
          if (locked) await handle!.unlock();
        } finally {
          try {
            await handle?.close();
          } finally {
            if (gated) await gate.delete();
          }
        }
      }
    } finally {
      finished.complete();
      if (identical(_tails[root.path], finished.future)) {
        _tails.remove(root.path);
      }
    }
  }
}

Future<void> regularFileOrAbsent(File file) async {
  final kind = await FileSystemEntity.type(file.path, followLinks: false);
  if (kind != FileSystemEntityType.file &&
      kind != FileSystemEntityType.notFound) {
    throw const GeoDataException(GeoDataError.denied);
  }
}
