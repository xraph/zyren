import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import '../plugins/attachment_scope.dart';
import '../rendering/frame_output.dart';
import 'asset_request.dart';
import 'image_decoder.dart';
import 'load_cancellation.dart';
import 'load_task.dart';
import 'source_resolver.dart';

part 'asset_services.dart';
part 'asset_decode_context.dart';
part 'shared_load.dart';

/// Owns load cancellation and retained CPU assets. Source decoding is supplied
/// by optional loaders; this scope does not imply a built-in format decoder.
class AssetScope {
  final AssetServices services;
  final _pending = <LoadTask<Object?>>{};
  final _assets = Map<Object, List<void Function()>>.identity();
  bool _closed = false;
  Future<void>? _closing;
  AssetScope({this.services = const AssetServices()});
  bool get isClosed => _closed;

  LoadTask<T> load<T extends Object>(AssetRequest<T> request) {
    if (_closed) throw StateError('Asset scope has been closed.');
    final task = services._pool.load(request, this);
    _track(task);
    return task;
  }

  void _retain(Object value, void Function() release) {
    if (_closed) {
      release();
      throw LoadCancelled();
    }
    (_assets[value] ??= []).add(release);
  }

  void _track(LoadTask<Object?> task) {
    _pending.add(task);
    task.result.then<void>(
      (_) => _pending.remove(task),
      onError: (Object _, StackTrace _) => _pending.remove(task),
    );
  }

  LoadTask<T> keep<T>(LoadTask<T> task) {
    if (_closed) {
      task.cancel();
      throw StateError('Asset scope has been closed.');
    }
    _track(task);
    task.result.then<void>(
      (value) {
        if (!_closed && value != null) _retain(value, () {});
      },
      onError: (Object _, StackTrace _) {
        _pending.remove(task);
      },
    );
    return task;
  }

  void release(Object asset) {
    final releases = _assets.remove(asset);
    if (releases == null) return;
    final errors = <Object>[];
    for (final release in releases.reversed) {
      try {
        release();
      } catch (error) {
        errors.add(error);
      }
    }
    if (errors.isNotEmpty) throw ScopeCleanupException(errors);
  }

  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    final completion = Completer<void>();
    _closing = completion.future;
    completion.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _closed = true;
    final errors = <Object>[];
    for (final task in List.of(_pending)) {
      try {
        task.cancel();
      } catch (error) {
        errors.add(error);
      }
    }
    _pending.clear();
    for (final asset in List.of(_assets.keys)) {
      try {
        release(asset);
      } catch (error) {
        errors.add(error);
      }
    }
    if (errors.isEmpty) {
      completion.complete();
    } else {
      completion.completeError(ScopeCleanupException(errors));
    }
    return completion.future;
  }
}
