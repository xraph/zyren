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
  final List<AnimationClip> animations;
  final List<SceneIssue> issues;
  final Uri sourceUri;
  final int? defaultSceneIndex;
  bool get isReleased => _shared == null;
  ModelAsset._(_SharedModel shared)
    : _shared = shared,
      animations = shared.animations,
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
  ModelInstance instantiate({String? name, int? sceneIndex}) {
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
    final bindings = <int, Object3D>{};
    Object3D node(int index) {
      final data = shared.nodes[index];
      final object = Group(name: data.name)
        ..position = data.position
        ..quaternion = data.rotation
        ..scale = data.scale;
      bindings[index] = object;
      if (data.light case final light?) object.add(light.instantiate());
      for (final child in data.children) {
        object.add(node(child));
      }
      return object;
    }

    final children = [for (final index in scene.roots) node(index)];
    final morphBindings = <int, List<Mesh>>{};
    final skins = <int, Skin>{};
    for (final entry in bindings.entries) {
      final data = shared.nodes[entry.key];
      if (data.mesh case final mesh?) {
        final Skin? skin = data.skin == null
            ? null
            : skins.putIfAbsent(data.skin!, () {
                final recipe = shared.skins[data.skin!];
                return Skin(
                  joints: [for (final joint in recipe.joints) bindings[joint]!],
                  inverseBindMatrices: recipe.inverseBindMatrices,
                );
              });
        for (final primitive in shared.meshes[mesh]) {
          final object = skin == null
              ? Mesh(
                  primitive.geometry,
                  primitive.material,
                  name: primitive.name,
                )
              : SkinnedMesh(
                  primitive.geometry,
                  primitive.material,
                  skin: skin,
                  name: primitive.name,
                );
          if (object.morphWeights.isNotEmpty) {
            object.morphWeights = data.weights;
            (morphBindings[entry.key] ??= []).add(object);
          }
          entry.value.add(object);
        }
      }
    }
    final root = ModelInstance._(
      bindings,
      morphBindings,
      shared.animations,
      name: name ?? scene.name,
    );
    for (final child in children) {
      root.add(child);
    }
    return root;
  }

  void _release() {
    _shared = null;
  }
}

/// One scene hierarchy with independent transforms and playback.
/// Node keys and clip indices match the source asset. Clips omit channels outside
/// this scene while retaining their original duration, including empty clips.
final class ModelInstance extends Group {
  final Map<int, Object3D> nodes;
  final Map<int, List<Mesh>> morphTargets;
  final List<AnimationClip> animations;
  late final AnimationMixer mixer = AnimationMixer(
    morphTargets: {
      for (final entry in morphTargets.entries)
        animationNodeTarget(entry.key): entry.value,
    },
    nodes: {
      for (final entry in nodes.entries)
        animationNodeTarget(entry.key): entry.value,
    },
  );
  ModelInstance._(
    Map<int, Object3D> nodes,
    Map<int, List<Mesh>> morphTargets,
    List<AnimationClip> source, {
    super.name,
  }) : morphTargets = Map.unmodifiable({
         for (final entry in morphTargets.entries)
           entry.key: List<Mesh>.unmodifiable(entry.value),
       }),
       nodes = Map.unmodifiable(nodes),
       animations = _sceneAnimations(nodes, source);
}

List<AnimationClip> _sceneAnimations(
  Map<int, Object3D> nodes,
  List<AnimationClip> source,
) {
  final targets = nodes.keys.map(animationNodeTarget).toSet();
  return List.unmodifiable([
    for (final clip in source)
      if (clip.tracks.every((t) => targets.contains(t.target)))
        clip
      else
        AnimationClip(
          name: clip.name,
          durationSeconds: clip.durationSeconds,
          tracks: clip.tracks.where((t) => targets.contains(t.target)).toList(),
        ),
  ]);
}

final class _SharedModel {
  final List<SkinRecipe> skins;
  final List<AnimationClip> animations;
  final List<NodeRecipe> nodes;
  final List<SceneRecipe> scenes;
  final int? defaultScene;
  final List<List<_ModelPrimitive>> meshes;
  final List<SceneIssue> issues;
  final Uri sourceUri;
  const _SharedModel(
    this.skins,
    this.animations,
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
