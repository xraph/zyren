part of '../resources/resource_scope.dart';

/// Backend adapter contract, exported only by zyren/rendering.dart.
abstract interface class ShaderDevice {
  Future<ShaderBuild> compileShader(ShaderSource source);
  Future<void> retainShader(Object key);
  Future<void> releaseShader(Object key);
}

/// Backend-owned tokens never appear on the public ShaderProgram API.
final class ShaderBuild {
  final Object key;
  final List<ShaderEntryPoint> entryPoints;
  final List<ShaderDiagnostic> diagnostics;
  ShaderBuild({
    required this.key,
    required Iterable<ShaderEntryPoint> entryPoints,
    Iterable<ShaderDiagnostic> diagnostics = const [],
  }) : entryPoints = List.unmodifiable(entryPoints),
       diagnostics = List.unmodifiable(diagnostics);
}

/// Owns compiled modules and drains accepted work before releasing them.
/// Obtain this from a shader-capable backend or a plugin attachment.
final class ShaderCompiler {
  final ShaderDevice _device;
  final String label;
  final _owned = <ShaderProgram>[];
  final _meshes = <MeshShaderProgram>[];
  final _pending = <Future<void>>{};
  final _closedSignal = Completer<void>();
  bool _closed = false;
  Future<void>? _closing;
  ShaderCompiler(this._device, {this.label = ''});
  bool get isClosed => _closed;
  Future<void> get whenClosed => _closedSignal.future;
  void _checkOpen() {
    if (_closed) throw StateError('Shader compiler has closed: $label');
  }

  Future<T> _run<T>(Future<T> Function() operation) {
    try {
      _checkOpen();
    } catch (error, stack) {
      return Future.error(error, stack);
    }
    final completion = Completer<T>();
    final result = completion.future;
    late Future<void> settled;
    settled = result
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          _pending.remove(settled);
        });
    _pending.add(settled);
    Future.sync(
      operation,
    ).then(completion.complete, onError: completion.completeError);
    return result;
  }

  Future<ShaderProgram> compile(ShaderSource source) => _run(() async {
    final build = await _device.compileShader(source);
    final program = ShaderProgram._(
      this,
      build.key,
      source,
      build.entryPoints,
      build.diagnostics,
    );
    _owned.add(program);
    _checkOpen();
    return program;
  });
  Future<ShaderProgram> retain(ShaderProgram program) => _run(() async {
    if (program.isClosed) throw StateError('Shader owner has closed.');
    if (!identical(_device, program._compiler._device)) {
      throw ArgumentError('Shader programs cannot cross native devices.');
    }
    await _device.retainShader(program._key);
    final retained = ShaderProgram._(
      this,
      program._key,
      program.source,
      program.entryPoints,
      program.diagnostics,
    );
    _owned.add(retained);
    _checkOpen();
    return retained;
  });
  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      await Future.wait(_pending.toList());
      final errors = <Object>[];
      for (final mesh in _meshes.reversed) {
        try {
          await mesh.close();
        } catch (error) {
          errors.add(error);
        }
      }
      _meshes.clear();
      for (final program in _owned.reversed) {
        try {
          await _device.releaseShader(program._key);
        } catch (error) {
          errors.add(error);
        }
      }
      _owned.clear();
      if (errors.isNotEmpty) throw ScopeCleanupException(errors);
    } finally {
      _closedSignal.complete();
    }
  }
}
