/// Optional disk persistence for runtime state. Authored saves use PipelineStudioStore.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:zyren/zyren.dart';
import 'zyren_game.dart';

final class FileGameSaveStore {
  final Directory directory;
  final String slot;
  final Future<void> Function(GameSave save)? beforePublish;
  static final Map<String, Future<void>> _tails = {};
  FileGameSaveStore({
    required this.directory,
    required this.slot,
    this.beforePublish,
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(slot)) {
      throw ArgumentError('Invalid save slot.');
    }
  }
  File get _file => File('${directory.path}/$slot.game.json');
  Future<T> _locked<T>(Future<T> Function() action) async {
    await directory.create(recursive: true);
    final key = _file.absolute.path;
    final previous = _tails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _tails[key] = done.future;
    try {
      await previous;
      final lock = await File(
        '${directory.path}/.$slot.lock',
      ).open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.exclusive);
        return await action();
      } finally {
        await lock.unlock();
        await lock.close();
      }
    } finally {
      done.complete();
      if (identical(_tails[key], done.future)) _tails.remove(key);
    }
  }

  Future<void> _recover() async {
    await for (final entry in directory.list(followLinks: false)) {
      final name = entry.uri.pathSegments.last;
      if (entry is File &&
          name.startsWith('.$slot.stage-') &&
          name.endsWith('.tmp')) {
        await entry.delete();
      }
    }
  }

  Future<GameSave?> read({
    Map<int, Map<String, Object?> Function(Map<String, Object?>)> migrations =
        const {},
  }) => _locked(() async {
    await _recover();
    if (!await _file.exists()) return null;
    if (await _file.length() > GameLimits.maxSourceBytes) {
      throw FormatException('Save exceeds byte limit.');
    }
    return GameSave.decode(await _file.readAsString(), migrations: migrations);
  });
  Future<void> write(GameSave save, {LoadCancellation? cancellation}) {
    final source = save.encode();
    return _locked(() async {
      cancellation?.throwIfCancelled();
      await _recover();
      final stage = File(
        '${directory.path}/.$slot.stage-${Random.secure().nextInt(0x7fffffff)}.tmp',
      );
      try {
        await stage.writeAsString(source, flush: true);
        cancellation?.throwIfCancelled();
        await beforePublish?.call(save);
        cancellation?.throwIfCancelled();
        await stage.rename(_file.path);
      } finally {
        if (await stage.exists()) await stage.delete();
      }
    });
  }
}
