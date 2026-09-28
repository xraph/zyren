import '../plugins/attachment_scope.dart';
import '../rendering/render_backend.dart';
import 'resource_scope.dart';

/// Independently retireable GPU work within a parent lifetime. A candidate can
/// close on failure while an earlier resource set keeps rendering. Closing a
/// parent synchronously stops all children and drains their accepted GPU work.
final class GpuScope {
  final MaterialBackend _backend;
  final ResourceScope resources;
  final ShaderCompiler shaders;
  final GraphCompiler graphs;
  final MaterialCompiler materials;
  final _children = <GpuScope>{};
  final _retirementErrors = <Object>[];
  bool _closed = false;
  Future<void>? _closing;
  GpuScope._(
    this._backend,
    this.resources,
    this.shaders,
    this.graphs,
    this.materials,
  );

  /// Advanced consumers can own a scope directly from a native backend.
  /// Plugins normally use PluginContext.createGpuScope instead.
  factory GpuScope.fromBackend(MaterialBackend backend, {String label = ''}) =>
      GpuScope._(
        backend,
        backend.createResourceScope(label: label),
        backend.createShaderCompiler(label: label),
        backend.createGraphCompiler(label: label),
        backend.createMaterialCompiler(label: label),
      );

  bool get isClosed => _closed;
  int get childCount => _children.length;
  GpuScope createChild({String label = ''}) {
    if (_closed) throw StateError('GPU scope has closed.');
    final child = GpuScope.fromBackend(_backend, label: label);
    _children.add(child);
    child._parent = this;
    return child;
  }

  GpuScope? _parent;

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    // Start every close before the first await, rejecting new work immediately.
    final operations = [
      for (final child in _children.toList()) child.close(),
      materials.close(),
      graphs.close(),
      shaders.close(),
      resources.close(),
    ];
    return _closing = _drain(operations);
  }

  Future<void> _drain(List<Future<void>> operations) async {
    final errors = <Object>[];
    await Future.wait([
      for (final operation in operations)
        operation.then<void>(
          (_) {},
          onError: (Object e, StackTrace _) {
            errors.add(e);
          },
        ),
    ]);
    _children.clear();
    final parent = _parent;
    _parent = null;
    parent?._children.remove(this);
    errors.addAll(_retirementErrors);
    if (errors.isNotEmpty) {
      final failure = ScopeCleanupException(errors);
      if (parent != null && !parent.isClosed) {
        parent._retirementErrors.add(failure);
      }
      throw failure;
    }
  }
}
