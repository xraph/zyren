import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';

/// Optional import enrichment. The host supplies source-owned node bindings from
/// its importer or sidecar; numeric glTF node indices are version-local only.
final class PipelineGltfMetadata {
  final String bundleVersion, sourceId, sourceRevision;
  final ModelInstance instance;
  final Map<int, String> sourceIds;
  final _bindings = Map<Object3D, int>.identity();
  PipelineGltfMetadata({
    required this.bundleVersion,
    required this.sourceId,
    required this.sourceRevision,
    required this.instance,
    required Map<int, String> sourceIds,
  }) : sourceIds = Map.unmodifiable(sourceIds) {
    final nodes = instance.nodes;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(bundleVersion) ||
        sourceId.isEmpty ||
        sourceId.length > 2048 ||
        sourceRevision.isEmpty ||
        sourceRevision.length > 2048 ||
        sourceIds.length > 4096 ||
        sourceIds.keys.any((index) => !nodes.containsKey(index)) ||
        sourceIds.values.any((id) => id.isEmpty || id.length > 2048) ||
        sourceIds.values.toSet().length != sourceIds.length) {
      throw ArgumentError(
        'Import bindings must name existing nodes with unique bounded identities.',
      );
    }
    for (final index in sourceIds.keys) {
      _bindings[nodes[index]!] = index;
    }
  }

  /// Enriches the nearest imported ancestor of a hit. Removed nodes are rejected.
  /// The host still owns scene/frame consistency and active viewport identity.
  Map<String, Object?>? inspect(Object3D object) {
    final ancestry = <Object3D>[];
    Object3D? cursor = object;
    while (cursor != null && !identical(cursor, instance)) {
      if (ancestry.length >= 1024) return null;
      ancestry.add(cursor);
      cursor = cursor.parent;
    }
    if (cursor == null) return null;
    for (final ancestor in ancestry) {
      final index = _bindings[ancestor];
      if (index == null) continue;
      return {
        'bundleVersion': bundleVersion,
        'sourceId': sourceId,
        'sourceRevision': sourceRevision,
        'nodeIndex': index,
        'stableObjectId': sourceIds[index],
        'runtimeObjectId': object.id,
        'boundNodeRuntimeId': ancestor.id,
        'identityMethod': 'host-import-binding',
        'bindingRelationship': identical(object, ancestor)
            ? 'self'
            : 'ancestor',
        'pixelVisibility': 'unknown',
      };
    }
    return null;
  }
}
