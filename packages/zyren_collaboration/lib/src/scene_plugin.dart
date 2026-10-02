import 'dart:async';
import 'package:zyren/zyren.dart';
import 'client.dart';
import 'model.dart';

/// Binds acknowledged state to a scene graph, including headless scene hosts.
/// Dispose this binding before closing its host-owned client.
final class SceneCollaborationBinding {
  final Scene scene;
  final SceneCollaborationClient client;
  final void Function()? invalidate;
  final _bindings = <SceneObjectId, Object3D>{};
  final _parents = <SceneObjectId, Object3D?>{};
  late final StreamSubscription<SceneSnapshot> _clientChanges;
  late final StreamSubscription<int> _sceneChanges;
  bool _closed = false;

  SceneCollaborationBinding({
    required this.scene,
    required this.client,
    this.invalidate,
  }) {
    if (client.isClosed) throw StateError('Collaboration client is closed.');
    _clientChanges = client.changes.listen(_apply);
    _sceneChanges = scene.changes.listen((_) {
      for (final id in _bindings.keys.toList()) {
        objectFor(id);
      }
    });
  }

  /// Rebind after an asset reload using the same source IDs and parent layout.
  /// A failed mapping keeps the previous bindings.
  void rebind(Map<SceneObjectId, Object3D> bindings) {
    if (_closed) throw StateError('Scene binding is closed.');
    final snapshot = client.snapshot;
    if (snapshot == null) {
      throw StateError('Read the scene before binding objects.');
    }
    final seen = <Object3D>{};
    for (final entry in bindings.entries) {
      if (!snapshot.objects.containsKey(entry.key) ||
          !_contains(entry.value) ||
          entry.value is Camera ||
          !seen.add(entry.value)) {
        throw ArgumentError(
          'Bindings need known IDs and distinct scene objects.',
        );
      }
    }
    _bindings
      ..clear()
      ..addAll(bindings);
    _parents
      ..clear()
      ..addAll(bindings.map((id, object) => MapEntry(id, object.parent)));
    _apply(snapshot);
  }

  Object3D? objectFor(SceneObjectId id) {
    final object = _bindings[id];
    if (object != null &&
        (!_contains(object) || !identical(_parents[id], object.parent))) {
      _bindings.remove(id);
      _parents.remove(id);
      return null;
    }
    return object;
  }

  Set<SceneObjectId> get unboundIds => Set.unmodifiable(
    client.snapshot?.objects.keys.where((id) => objectFor(id) == null) ??
        const <SceneObjectId>[],
  );

  bool _contains(Object3D object) {
    if (_closed) return false;
    for (var parent = object.parent; parent != null; parent = parent.parent) {
      if (identical(parent, scene)) return true;
    }
    return false;
  }

  void _apply(SceneSnapshot snapshot) {
    if (_closed) return;
    var changed = false;
    scene.batch(() {
      for (final entry in _bindings.entries.toList()) {
        final object = objectFor(entry.key);
        final state = snapshot.objects[entry.key];
        if (object == null || state == null) continue;
        if (SceneTransform.capture(object) != state.transform ||
            object.visible != state.visible) {
          state.transform.apply(object);
          object.visible = state.visible;
          changed = true;
        }
      }
    });
    if (changed) invalidate?.call();
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    _bindings.clear();
    _parents.clear();
    await _clientChanges.cancel();
    await _sceneChanges.cancel();
  }
}

/// Attaches collaboration bindings to the normal plugin lifetime and frame demand.
final class SceneCollaborationPlugin extends ScenePlugin {
  final SceneCollaborationClient client;
  SceneCollaborationBinding? _binding;
  PluginContext? _context;
  SceneCollaborationPlugin(this.client);
  @override
  String get id => 'zyren.collaboration';
  SceneCollaborationBinding get binding =>
      _binding ?? (throw StateError('Attach the collaboration plugin first.'));
  @override
  void attach(PluginContext context) {
    if (_context != null) {
      throw StateError('Collaboration is already attached.');
    }
    _binding = SceneCollaborationBinding(
      scene: context.scene,
      client: client,
      invalidate: context.invalidate,
    );
    _context = context;
  }

  @override
  Future<void> detach(PluginContext context) async {
    if (!identical(_context, context)) return;
    _context = null;
    final binding = _binding;
    _binding = null;
    await binding?.dispose();
  }
}
