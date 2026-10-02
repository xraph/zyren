part of '../resources/resource_scope.dart';

/// Advanced adapter contract. Material tokens are opaque, generation-scoped IDs.
abstract interface class MaterialDevice implements GraphDevice {
  Future<Object> compileMaterial(GraphDeviceDescription description);
  Future<void> retainMaterial(Object key);
  Future<void> releaseMaterial(Object key);
  Uint8List encodeMaterialKey(Object key);
}

/// Group 0 belongs to the renderer. Readonly user bindings occupy groups 1 to 3.
class MeshShaderDescriptor {
  final ShaderProgram program;
  final ShaderBindings bindings;
  final String label, vertexEntryPoint, fragmentEntryPoint;
  final bool requiresUv;

  /// The fragment entry calls the meshClip WGSL helper with its camera-relative
  /// position. Leave false for shaders without the standard clipping hook.
  final bool supportsClipping;
  MeshShaderDescriptor({
    required this.program,
    ShaderBindings? bindings,
    this.label = 'mesh material',
    this.vertexEntryPoint = 'vertex',
    this.fragmentEntryPoint = 'fragment',
    this.requiresUv = false,
    this.supportsClipping = false,
  }) : bindings = bindings ?? ShaderBindings(const []);
}

final class _MaterialPassDescriptor extends PassDescriptor {
  final MeshShaderDescriptor descriptor;
  _MaterialPassDescriptor(this.descriptor)
    : super(
        name: descriptor.label,
        program: descriptor.program,
        bindings: descriptor.bindings,
        reads: descriptor.bindings.entries
            .where((b) => b._reads)
            .map((b) => b.resource)
            .nonNulls,
        writes: [
          ...descriptor.bindings.entries
              .where((b) => b._writes)
              .map((b) => b.resource)
              .nonNulls,
          if (descriptor case PostProcessDescriptor(target: final target?))
            target,
        ],
      );
}

/// Compiles independent immutable candidates. Failed edits leave prior shaders
/// owned and usable until this compiler closes.
final class MaterialCompiler {
  final MaterialDevice _device;
  final String label;
  final _owned = <MeshShader>[];
  final _pending = <Future<void>>{};
  final _closedSignal = Completer<void>();
  bool _closed = false;
  Future<void>? _closing;
  MaterialCompiler(this._device, {this.label = ''});
  bool get isClosed => _closed;
  Future<void> get whenClosed => _closedSignal.future;

  Future<ScreenEffect> compileEffect(PostProcessDescriptor descriptor) async =>
      ScreenEffect._(await compile(descriptor));

  Future<ScreenEffect> retainEffect(ScreenEffect effect) async =>
      ScreenEffect._(await retain(effect._shader));

  Future<MeshShader> compile(MeshShaderDescriptor descriptor) {
    return _run(() async {
      for (final binding in descriptor.bindings.entries) {
        final screenOutput =
            descriptor is PostProcessDescriptor &&
            binding is TextureBinding &&
            binding.storage &&
            (binding.visibility == null ||
                binding.visibility!.length == 1 &&
                    binding.visibility!.contains(ShaderStage.fragment));
        if (binding.group == 0 || binding._writes && !screenOutput) {
          throw GraphException(
            GraphErrorCode.invalidBinding,
            'Group 0 is reserved. Only screen effects can write fragment-only storage textures.',
          );
        }
      }
      final pass = _MaterialPassDescriptor(descriptor);
      final description = _prepareGraph(
        GraphDescription(
          label: descriptor.label,
          passes: [pass],
          inputs: pass.reads,
        ),
        _device,
      ).$1;
      final key = await _device.compileMaterial(description);
      final shader = MeshShader._(this, key, descriptor);
      _owned.add(shader);
      if (_closed) {
        throw StateError('Material compiler closed during compilation.');
      }
      return shader;
    });
  }

  Future<MeshShader> retain(MeshShader shader) => _run(() async {
    if (shader.isClosed) throw StateError('Material shader owner has closed.');
    if (!identical(_device, shader._compiler._device)) {
      throw GraphException(
        GraphErrorCode.foreignResource,
        'Material belongs to another device.',
      );
    }
    await _device.retainMaterial(shader._key);
    final retained = MeshShader._(this, shader._key, shader.descriptor);
    _owned.add(retained);
    if (_closed) throw StateError('Material compiler closed during retention.');
    return retained;
  });

  Future<MeshShader> _run(Future<MeshShader> Function() operation) {
    if (_closed) {
      return Future.error(StateError('Material compiler has closed: $label'));
    }
    final future = Future.sync(operation);
    late Future<void> settled;
    settled = future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(settled));
    _pending.add(settled);
    return future;
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    final errors = <Object>[];
    try {
      await Future.wait(_pending.toList());
      for (final shader in _owned.reversed) {
        try {
          await _device.releaseMaterial(shader._key);
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

/// A checked shader/layout with independently retained native bindings.
final class MeshShader {
  final MaterialCompiler _compiler;
  final Object _key;
  final MeshShaderDescriptor descriptor;
  MeshShader._(this._compiler, this._key, this.descriptor);
  bool get isClosed => _compiler.isClosed;

  /// Adapter encoding only. Tokens are valid on their creating device generation.
  Uint8List encodeForDevice(MaterialDevice device) {
    if (isClosed) throw StateError('Material shader owner has closed.');
    if (!identical(device, _compiler._device)) {
      throw GraphException(
        GraphErrorCode.foreignResource,
        'Material belongs to another device.',
      );
    }
    final bytes = device.encodeMaterialKey(_key);
    if (bytes.length != 32) {
      throw StateError('Invalid material token encoding.');
    }
    return bytes;
  }
}
