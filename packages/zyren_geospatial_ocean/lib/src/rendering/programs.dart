import 'package:zyren/zyren.dart';

/// Shares a bounded set of water shader modules across patch-specific bindings.
/// Close after the materials, or let their parent quality scope retire both.
final class OceanWaterPrograms {
  final GpuScope _scope;
  final Map<String, Future<ShaderProgram>> _modules = {};
  OceanWaterPrograms(GpuScope parent)
    : _scope = parent.createChild(label: 'ocean-water-programs');
  bool get isClosed => _scope.isClosed;
  int get moduleCount => _modules.length;
  Future<MeshShaderProgram> bind(
    GpuScope owner,
    ShaderSource source, {
    required ShaderBindings bindings,
    required MeshShaderGeometry geometry,
    MeshSceneInputs sceneInputs = MeshSceneInputs.none,
  }) async {
    if (isClosed) throw StateError('Water shader library closed.');
    if (!_modules.containsKey(source.code) && _modules.length >= 16) {
      throw const ResourceException(
        ResourceErrorCode.budgetExceeded,
        'Water shader library exceeds sixteen module variants.',
      );
    }
    final future = _modules.putIfAbsent(
      source.code,
      () => _scope.shaders.compile(source),
    );
    final ShaderProgram module;
    try {
      module = await future;
    } catch (_) {
      if (identical(_modules[source.code], future)) {
        _modules.remove(source.code);
      }
      rethrow;
    }
    return owner.shaders.bindMesh(
      module,
      bindings: bindings,
      geometry: geometry,
      sceneInputs: sceneInputs,
    );
  }

  Future<void> close() => _scope.close();
}
