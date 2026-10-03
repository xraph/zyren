import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_gltf_timeline/agents.dart';
import 'package:zyren_studio/zyren_studio.dart';

/// Providers refer to the imported instances in the editor's current hierarchy.
/// Reconstruction retires old registrations before publishing replacement tools.
class StudioModelBindings {
  final StudioScene scene;
  final AgentRegistry registry;
  final _leases = <ModelInstance, Registration>{};
  bool _closed = false;
  StudioModelBindings(this.scene, this.registry);

  void synchronize() {
    if (_closed) return;
    final models = <ModelInstance, String>{};
    void visit(Object3D object, String sourceId) {
      if (object is ModelInstance) models[object] = sourceId;
      for (final child in object.children) {
        visit(child, sourceId);
      }
    }

    for (final node in scene.document.expandedNodes.values) {
      if (node.kind != StudioNodeKind.asset) continue;
      final object = scene.objects[node.id];
      if (object != null) {
        visit(object, node.sourceId ?? node.assetId ?? node.id);
      }
    }
    for (final model in _leases.keys.toList()) {
      if (!models.containsKey(model)) _leases.remove(model)!.dispose();
    }
    for (final entry in models.entries) {
      _leases.putIfAbsent(
        entry.key,
        () => registry.register(
          ModelAnimationAgentProvider(
            model: entry.key,
            instanceId: 'model-${entry.key.id}',
            sourceId: entry.value,
            readRevision: () => scene.revision,
            isAvailable: () => !_closed && scene.idFor(entry.key) != null,
          ),
        ),
      );
    }
  }

  void dispose() {
    _closed = true;
    for (final lease in _leases.values) {
      lease.dispose();
    }
    _leases.clear();
  }
}
