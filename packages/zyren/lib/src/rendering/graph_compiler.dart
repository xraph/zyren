part of '../resources/resource_scope.dart';

/// Advanced adapter contract. Description keys belong to this device only.
abstract interface class GraphDevice implements ResourceDevice, ShaderDevice {
  Future<Object> compileGraph(GraphDeviceDescription description);
  Future<GraphStats> executeGraph(Object key);
  Future<void> releaseGraph(Object key);
}

final class GraphDeviceDescription {
  final Map<String, Object?> data;
  GraphDeviceDescription(this.data);
}

/// Owns one active graph. Failed candidates preserve it; successful ones replace it.
final class GraphCompiler {
  final GraphDevice _device;
  final String label;
  final _closedSignal = Completer<void>();
  final _retirementErrors = <Object>[];
  CompiledGraph? _active;
  Future<CompiledGraph>? _compiling;
  Future<void>? _closing;
  bool _closed = false;
  GraphCompiler(this._device, {this.label = ''});
  CompiledGraph? get active => _active;
  bool get isClosed => _closed;
  Future<void> get whenClosed => _closedSignal.future;

  Future<CompiledGraph> compile(GraphDescription description) {
    if (_closed) {
      return Future.error(StateError('Graph compiler has closed: $label'));
    }
    if (_compiling != null) {
      return Future.error(
        StateError(
          'Await the pending graph compilation before compiling another candidate.',
        ),
      );
    }
    final future = _compile(description);
    _compiling = future;
    return future.whenComplete(() {
      _compiling = null;
    });
  }

  Future<CompiledGraph> _compile(GraphDescription description) async {
    final prepared = _prepareGraph(description, _device);
    final key = await _device.compileGraph(prepared.$1);
    final candidate = CompiledGraph._(
      _device,
      key,
      description.label,
      prepared.$2,
      prepared.$3,
    );
    if (_closed) {
      await _retire(candidate);
      throw StateError('Graph compiler closed during compilation.');
    }
    final previous = _active;
    _active = candidate;
    await _retire(previous);
    if (_closed) {
      await _retire(candidate);
      throw StateError('Graph compiler closed during replacement.');
    }
    return candidate;
  }

  Future<void> _retire(CompiledGraph? graph) async {
    try {
      await graph?.close();
    } catch (error) {
      if (!_retirementErrors.contains(error)) _retirementErrors.add(error);
    }
  }

  Future<void> close() {
    _closed = true;
    _active?.close().then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      try {
        await _compiling;
      } catch (_) {
        /* The compilation caller receives this failure. */
      }
      final active = _active;
      _active = null;
      await _retire(active);
      if (_retirementErrors.isNotEmpty) {
        throw ScopeCleanupException(_retirementErrors);
      }
    } finally {
      _closedSignal.complete();
    }
  }
}

/// Retains its programs and resources natively until accepted executions finish.
final class CompiledGraph {
  final GraphDevice _device;
  final Object _key;
  final String label;
  final List<String> passNames;
  final List<GraphResourceLifetime> lifetimes;
  final _pending = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closing;
  CompiledGraph._(
    this._device,
    this._key,
    this.label,
    Iterable<String> passNames,
    Iterable<GraphResourceLifetime> lifetimes,
  ) : passNames = List.unmodifiable(passNames),
      lifetimes = List.unmodifiable(lifetimes);
  bool get isClosed => _closed;
  Future<GraphStats> execute() {
    if (_closed) {
      return Future.error(StateError('Compiled graph has closed: $label'));
    }
    final future = Future.sync(() => _device.executeGraph(_key));
    late Future<void> settled;
    settled = future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _pending.remove(settled);
        });
    _pending.add(settled);
    return future;
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await Future.wait(_pending.toList());
    await _device.releaseGraph(_key);
  }
}
