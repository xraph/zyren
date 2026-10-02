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
  final List<ModelAnimation> animations;
  final List<SceneIssue> issues;
  final Uri sourceUri;
  final String? copyright;
  final List<ModelPropertyTable> propertyTables;
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
      copyright = shared.copyright,
      propertyTables = shared.propertyTables,
      defaultSceneIndex = shared.defaultScene;

  /// Uses the declared default scene, or the first scene when none is declared.
  /// Assets with no scenes remain loadable but cannot be instantiated.
  ModelInstance instantiate({
    bool nativeDeformation = true,
    String? name,
    int? sceneIndex,
  }) {
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
    final deformers = <_InstanceDeformer>[];
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
          final deform = nativeDeformation ? null : primitive.deformation;
          final geometry = !nativeDeformation && deform != null
              ? BufferGeometry.fromAttributes(
                  attributes: {
                    for (final e in primitive.geometry.attributes.entries)
                      if (e.key != VertexSemantic.joints &&
                          e.key != VertexSemantic.weights)
                        e.key: e.value,
                  },
                  indices: primitive.geometry.indices,
                  indexFormat: primitive.geometry.indexFormat,
                  topology: primitive.geometry.topology,
                  dynamic: true,
                )
              : primitive.geometry;
          final object = skin == null || !nativeDeformation
              ? ModelMesh(
                  geometry,
                  primitive.material,
                  features: primitive.features,
                  name: primitive.name,
                )
              : ModelSkinnedMesh(
                  geometry,
                  primitive.material,
                  skin: skin,
                  features: primitive.features,
                  name: primitive.name,
                );
          if (!nativeDeformation && deform != null) {
            deformers.add(
              _InstanceDeformer(
                entry.key,
                object,
                primitive,
                data.weights,
                data.skin,
              ),
            );
          }
          if (object.morphWeights.isNotEmpty) {
            object.morphWeights = data.weights;
            (morphBindings[entry.key] ??= []).add(object);
          }
          entry.value.add(object);
        }
      }
    }
    final root = ModelInstance._(
      shared,
      bindings,
      deformers,
      morphBindings,
      nativeDeformation,
      name: name ?? scene.name,
    );
    for (final child in children) {
      root.add(child);
    }
    root._captureParents();
    if (!nativeDeformation) root.preparePose()();
    return root;
  }

  void _release() {
    _shared = null;
  }
}

List<ModelAnimation> _sceneAnimations(
  Map<int, Object3D> nodes,
  List<ModelAnimation> source,
) {
  final targets = nodes.keys.map(animationNodeTarget).toSet();
  return List.unmodifiable([
    for (final clip in source)
      if (clip.tracks.every((t) => targets.contains(t.target)))
        clip
      else
        ModelAnimation.fromClip(
          AnimationClip(
            name: clip.name,
            durationSeconds: clip.durationSeconds,
            tracks: clip.tracks
                .where((t) => targets.contains(t.target))
                .toList(),
          ),
          events: clip.events,
        ),
  ]);
}

final class _SharedModel {
  final List<SkinRecipe> skins;
  final List<ModelAnimation> animations;
  final List<NodeRecipe> nodes;
  final List<SceneRecipe> scenes;
  final int? defaultScene;
  final List<List<_ModelPrimitive>> meshes;
  final List<SceneIssue> issues;
  final Uri sourceUri;
  final String? copyright;
  final List<ModelPropertyTable> propertyTables;
  const _SharedModel(
    this.skins,
    this.animations,
    this.nodes,
    this.scenes,
    this.defaultScene,
    this.meshes,
    this.issues,
    this.sourceUri,
    this.copyright,
    this.propertyTables,
  );
}

final class _ModelPrimitive {
  final BufferGeometry geometry;
  final MeshMaterial material;
  final String? name;
  final List<ModelFeature> features;
  _ModelPrimitive(this.geometry, this.material, this.name, this.features);
  late final PrimitiveDeformation? deformation = _deformation();
  PrimitiveDeformation? _deformation() {
    final targets = geometry.morphTargets;
    final joints = geometry.attributes[VertexSemantic.joints]?.data;
    if (targets.isEmpty && joints == null) return null;
    List<double> delta(MorphTarget target, VertexSemantic key) =>
        (switch (key) {
          VertexSemantic.position => target.positions,
          VertexSemantic.normal => target.normals,
          _ => target.tangents,
        })?.toList() ??
        List.filled(geometry.vertexCount * 3, 0);
    return PrimitiveDeformation(
      morphPositions: [
        for (final t in targets) delta(t, VertexSemantic.position),
      ],
      morphNormals: [for (final t in targets) delta(t, VertexSemantic.normal)],
      morphTangents: [
        for (final t in targets) delta(t, VertexSemantic.tangent),
      ],
      joints: (joints as Uint16List?)?.toList() ?? const [],
      weights:
          (geometry.attributes[VertexSemantic.weights]?.data as Float32List?)
              ?.toList() ??
          const [],
    );
  }
}
