part of 'loader.dart';

final class ModelSceneInfo {
  final int index, rootCount;
  final String? name;
  const ModelSceneInfo._(this.index, this.name, this.rootCount);
}

/// A scope-owned model template. Instances keep their geometry and textures
/// after [AssetScope.release] prevents further instantiation of this template.
final class ModelAsset {
  _SharedModel? _shared;
  final List<ModelSceneInfo> scenes;
  final List<SceneIssue> issues;
  final Uri sourceUri;
  final int? defaultSceneIndex;
  bool get isReleased => _shared == null;
  ModelAsset._(_SharedModel shared)
    : _shared = shared,
      scenes = List.unmodifiable([
        for (var i = 0; i < shared.scenes.length; i++)
          ModelSceneInfo._(
            i,
            shared.scenes[i].name,
            shared.scenes[i].roots.length,
          ),
      ]),
      issues = shared.issues,
      sourceUri = shared.sourceUri,
      defaultSceneIndex = shared.defaultScene;

  /// Uses the declared default scene, or the first scene when none is declared.
  /// Assets with no scenes remain loadable but cannot be instantiated.
  Group instantiate({String? name, int? sceneIndex}) {
    final shared = _shared;
    if (shared == null) {
      throw StateError('The model template has been released.');
    }
    if (shared.scenes.isEmpty) {
      throw StateError('The model contains no scenes.');
    }
    final selected = sceneIndex ?? shared.defaultScene ?? 0;
    RangeError.checkValidIndex(selected, shared.scenes, 'sceneIndex');
    final scene = shared.scenes[selected];
    Object3D node(int index) {
      final data = shared.nodes[index];
      final object = Group(name: data.name)
        ..position = data.position
        ..quaternion = data.rotation
        ..scale = data.scale;
      if (data.light case final light?) {
        object.add(light.instantiate());
      }
      if (data.mesh case final mesh?) {
        for (final primitive in shared.meshes[mesh]) {
          object.add(
            Mesh(primitive.geometry, primitive.material, name: primitive.name),
          );
        }
      }
      for (final child in data.children) {
        object.add(node(child));
      }
      return object;
    }

    final root = Group(name: name ?? scene.name);
    for (final index in scene.roots) {
      root.add(node(index));
    }
    return root;
  }

  void _release() {
    _shared = null;
  }
}

final class _SharedModel {
  final List<NodeRecipe> nodes;
  final List<SceneRecipe> scenes;
  final int? defaultScene;
  final List<List<_ModelPrimitive>> meshes;
  final List<SceneIssue> issues;
  final Uri sourceUri;
  const _SharedModel(
    this.nodes,
    this.scenes,
    this.defaultScene,
    this.meshes,
    this.issues,
    this.sourceUri,
  );
}

final class _ModelPrimitive {
  final BufferGeometry geometry;
  final MeshMaterial material;
  final String? name;
  const _ModelPrimitive(this.geometry, this.material, this.name);
}
