import 'dart:typed_data';
import 'color_pipeline.dart';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../geometry/geometry.dart';
import '../geometry/vertex_attribute.dart';
import '../resources/texture_image.dart';
import '../scene/scene.dart';
import 'frame_output.dart';
import '../resources/resource_scope.dart';
part 'scene_packet.dart';
part 'shadow_capture.dart';

class FrameTime {
  final Duration elapsed, delta, rawDelta;
  final int index;
  const FrameTime({
    this.elapsed = Duration.zero,
    this.delta = Duration.zero,
    this.rawDelta = Duration.zero,
    this.index = 0,
  });
  double get elapsedSeconds =>
      elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  double get deltaSeconds =>
      delta.inMicroseconds / Duration.microsecondsPerSecond;
}

class CameraSnapshot {
  final List<double> origin, viewProjection, projection;
  CameraSnapshot._(
    Iterable<double> origin,
    Iterable<double> viewProjection,
    Iterable<double> projection,
  ) : origin = List.unmodifiable(origin),
      viewProjection = List.unmodifiable(viewProjection),
      projection = List.unmodifiable(projection);
}

/// Captured transforms with shared immutable CPU geometry recipes.
class SceneSnapshot {
  final List<_ShadowLight> _shadowLights;
  bool get hasShadows =>
      _shadowLights.isNotEmpty ||
      _meshes.any(
        (mesh) => mesh['cast_shadow'] == true || mesh['receive_shadow'] == true,
      );
  final List<Map<String, Object>> _meshes;
  final List<Map<String, Object>> _lights, _hemispheres;
  bool get hasStandardMaterials => _meshes.any((m) => m.containsKey('pbr'));
  int get punctualLightCount => _lights.length;
  int get hemisphereLightCount => _hemispheres.length;
  final Map<int, GeometrySnapshot> _geometries;
  final Map<int, InstanceSnapshot> _instances;
  final Map<int, DeformationSnapshot> _poses;
  bool get hasDeformation => _poses.isNotEmpty;
  bool get hasInstances => _instances.isNotEmpty;
  final Map<int, TextureImage> _textures;
  final List<double> _background, _light;
  final double _ambient;
  final double backgroundOpacity;

  /// One resolve draw converts a transparent scene to straight color.
  int get alphaResolveDraws => backgroundOpacity < 1 ? 1 : 0;
  final Map<int, MeshShaderProgram> meshShaders;
  int get drawCalls => _meshes.fold(
    0,
    (n, mesh) =>
        n + (mesh['alpha_mode'] == 2 ? mesh['instance_count'] as int : 1),
  );
  int get triangles => _meshes.fold(0, (sum, mesh) {
    final geometry = _geometries[mesh['geometry']]!;
    return sum +
        (mesh['instance_count'] as int) *
            geometry.primitiveCount *
            (geometry.topology == GeometryTopology.triangles ? 1 : 2);
  });
  SceneSnapshot._(
    this._meshes,
    this._lights,
    this._hemispheres,
    this._geometries,
    this._instances,
    this._poses,
    this._textures,
    this._background,
    this.backgroundOpacity,
    this._light,
    this._ambient,
    this.meshShaders,
    this._shadowLights,
  );
  static SceneSnapshot _capture(Scene scene, Camera camera) {
    final meshes = <Map<String, Object>>[],
        geometries = <int, GeometrySnapshot>{};
    final textures = <int, TextureImage>{};
    final instances = <int, InstanceSnapshot>{};
    final poses = <int, DeformationSnapshot>{};
    var instanceCapacity = 0;
    final lights = <Map<String, Object>>[];
    final hemispheres = <Map<String, Object>>[];
    final meshShaders = <int, MeshShaderProgram>{};
    final shadows = <_ShadowLight>[];
    void visit(Object3D node, vm.Matrix4 parent, bool parentVisible) {
      final visible = parentVisible && node.visible;
      final world = parent * node.localMatrix.toVectorMath();
      if (visible && node is HemisphereLight) {
        if (hemispheres.length >= 4) {
          throw ArgumentError(
            'A scene supports at most 4 visible hemisphere lights.',
          );
        }
        final direction = vm.Vector3(
          world.entry(0, 1),
          world.entry(1, 1),
          world.entry(2, 1),
        );
        if (!direction.length2.isFinite || direction.length2 < 1e-30) {
          throw ArgumentError(
            'Hemisphere direction must be finite and nonzero.',
          );
        }
        direction.normalize();
        hemispheres.add(
          _freeze(<String, Object>{
                'sky_color': node.skyColor.toList(),
                'ground_color': node.groundColor.toList(),
                'direction': direction.storage.toList(),
                'intensity': node.intensity,
              })
              as Map<String, Object>,
        );
      }
      if (visible && node is PunctualLight) {
        if (lights.length >= 16) {
          throw ArgumentError(
            'A scene supports at most 16 visible punctual lights.',
          );
        }
        final direction = vm.Vector3(
          -world.entry(0, 2),
          -world.entry(1, 2),
          -world.entry(2, 2),
        );
        if (!direction.length2.isFinite || direction.length2 < 1e-30) {
          throw ArgumentError('Light direction must be finite and nonzero.');
        }
        direction.normalize();
        if (node.shadow case final settings?) {
          shadows.add(
            _ShadowLight(lights.length, settings, node.shadowRevision),
          );
        }
        final position =
            world.getTranslation() - camera.position.toVectorMath();
        lights.add(
          _freeze(<String, Object>{
                'kind': switch (node) {
                  DirectionalLight() => 0,
                  PointLight() => 1,
                  SpotLight() => 2,
                },
                'color': node.color.toList(),
                'intensity': node.intensity,
                'position': position.storage.toList(),
                'direction': direction.storage.toList(),
                'range': node is PositionalLight ? node.range ?? 0.0 : 0.0,
                'inner_cos': node is SpotLight
                    ? math.cos(node.innerConeAngle)
                    : 1.0,
                'outer_cos': node is SpotLight
                    ? math.cos(node.outerConeAngle)
                    : 0.0,
              })
              as Map<String, Object>,
        );
      }
      if (node is Mesh) {
        final instance = node is InstancedMesh ? node.captureInstances() : null;
        if (instance != null) {
          if ((instanceCapacity += instance.capacity) > 100000) {
            throw ArgumentError(
              'A scene view supports at most 100000 instance slots.',
            );
          }
          instances[instance.id] = instance;
        }
        if (node is SkinnedMesh) {
          for (final joint in node.skin.joints) {
            Object3D? owner = joint;
            while (owner != null && !identical(owner, scene)) {
              owner = owner.parent;
            }
            if (owner == null) {
              throw ArgumentError(
                'Skin joints must belong to the rendered scene.',
              );
            }
          }
        }
        final pose = node.captureDeformation();
        if (pose != null) poses[pose.id] = pose;
        final geometry = node.geometry.capture();
        geometries[geometry.id] = geometry;
        final map = node.material.colorMap;
        for (final binding in node.material.textureMaps) {
          textures[binding.image.id] = binding.image;
        }
        if (visible && (node is! InstancedMesh || node.count > 0)) {
          if (node.material.vertexColors && geometry.colors == null) {
            throw ArgumentError('Vertex colors require a color attribute.');
          }
          if (node.material case ShaderMaterial(:final program)) {
            if (instance != null || pose != null) {
              throw UnsupportedError(
                "Instancing and deformation require a built-in material.",
              );
            }
            if (program.isClosed) {
              throw StateError('Mesh shader has closed: ${program.label}');
            }
            if (program.vertexLayout == MeshVertexLayout.positionNormalUv &&
                node.geometry.uv0 == null &&
                node.geometry.uv1 == null) {
              throw ArgumentError('This mesh shader requires UV attributes.');
            }
            meshShaders[meshes.length] = program;
          }
          for (final binding in node.material.textureMaps) {
            if ((binding.uvSet == 0 ? geometry.uv0 : geometry.uv1) == null) {
              throw ArgumentError(
                'A material map requires UV set ${binding.uvSet}.',
              );
            }
          }
          final relative = world.clone()
            ..setTranslation(
              world.getTranslation() - camera.position.toVectorMath(),
            );
          meshes.add(
            _freeze(<String, Object>{
                  'geometry': geometry.id,
                  'instances': instance?.id ?? 0,
                  'pose': pose?.id ?? 0,
                  'instance_count': node is InstancedMesh ? node.count : 1,
                  if (node.castShadow) 'cast_shadow': true,
                  if (node.receiveShadow) 'receive_shadow': true,
                  'model': relative.storage.toList(),
                  'color': node.material.color.toList(),
                  'unlit': node.material.unlit,
                  if (node.material.vertexColors) 'vertex_colors': true,
                  if (node.material case StandardMaterial material)
                    'pbr': <String, Object>{
                      'metallic': material.metallic,
                      'roughness': material.roughness,
                      'normal_scale': material.normalScale,
                      'occlusion_strength': material.occlusionStrength,
                      if (material.normalMap != null)
                        'normal_map': material.normalMap!.toPacket(),
                      if (material.metallicRoughnessMap != null)
                        'metallic_roughness_map': material.metallicRoughnessMap!
                            .toPacket(),
                      if (material.occlusionMap != null)
                        'occlusion_map': material.occlusionMap!.toPacket(),
                      if (material.emissiveMap != null)
                        'emissive_map': material.emissiveMap!.toPacket(),
                      'emissive': material.emissive
                          .toList()
                          .map((v) => v * material.emissiveIntensity)
                          .toList(),
                    },
                  'side': node.material.side.index,
                  'alpha_mode': node.material.alphaMode.index,
                  'opacity': node.material.opacity,
                  'alpha_cutoff': node.material.alphaCutoff,
                  'depth_test': node.material.depthTest,
                  'depth_write': node.material.writesDepth,
                  'render_order': node.renderOrder,
                  'primitive_kind': node.material.primitiveKind,
                  'primitive_size': node.material.primitiveSize,
                  'size_units': node.material.sizeUnits.index,
                  'point_shape': node.material.pointShape.index,
                  'colorMap': map?.toPacket() ?? <int>[],
                })
                as Map<String, Object>,
          );
        }
      }
      for (final child in node.children) {
        visit(child, world, visible);
      }
    }

    visit(scene, vm.Matrix4.identity(), true);
    return SceneSnapshot._(
      List.unmodifiable(meshes),
      List.unmodifiable(lights),
      List.unmodifiable(hemispheres),
      Map.unmodifiable(geometries),
      Map.unmodifiable(instances),
      Map.unmodifiable(poses),
      Map.unmodifiable(textures),
      List.unmodifiable(scene.background?.toList() ?? [0.0, 0.0, 0.0]),
      scene.background == null
          ? 0.0
          : Float32List.fromList([scene.backgroundOpacity]).single,
      List.unmodifiable(scene.lightDirection.storage),
      scene.ambient,
      Map.unmodifiable(meshShaders),
      List.unmodifiable(shadows),
    );
  }
}

class FrameSubmission {
  final ShadowSnapshot shadows;
  final CompiledGraph? graph;
  final ColorPipeline? colorPipeline;
  final Environment? environment;
  final SceneSnapshot scene;
  final CameraSnapshot camera;
  final OutputTarget target;
  final PhysicalSize size;
  final FrameTime time;
  final Duration cpuBuildTime;
  FrameSubmission._(
    this.scene,
    this.camera,
    this.target,
    this.size,
    this.time,
    this.cpuBuildTime,
    this.graph,
    this.colorPipeline,
    this.environment,
    this.shadows,
  );

  /// Captures once so changes made during an asynchronous render affect only
  /// later submissions. This does not allocate a GPU or require Flutter.
  factory FrameSubmission.capture({
    required Scene scene,
    required Camera camera,
    required PhysicalSize size,
    OutputTarget target = const ReadbackTarget(),
    FrameTime time = const FrameTime(),
    CompiledGraph? graph,
    ColorPipeline? colorPipeline,
    Environment? environment,
  }) {
    final clock = Stopwatch()..start();

    final cameraSnapshot = CameraSnapshot._(
      camera.position.storage,
      camera.viewProjection(size.width / size.height).storage,
      camera.projectionMatrix(size.width / size.height).storage,
    );
    final sceneSnapshot = SceneSnapshot._capture(scene, camera);
    return FrameSubmission._(
      sceneSnapshot,
      cameraSnapshot,
      target,
      size,
      time,
      clock.elapsed,
      graph,
      colorPipeline,
      environment,
      ShadowSnapshot.capture(sceneSnapshot, camera, size.width / size.height),
    );
  }

  /// Selects a compiled graph without recapturing mutable scene or camera state.
  FrameSubmission withGraph(CompiledGraph? graph) => FrameSubmission._(
    scene,
    camera,
    target,
    size,
    time,
    cpuBuildTime,
    graph,
    colorPipeline,
    environment,
    shadows,
  );

  /// Compatibility encoder for native v1 adapters. Geometry conversion is lazy.
  Map<String, Object> toNativePacket({Set<int> uploaded = const {}}) {
    if (graph != null ||
        environment != null ||
        scene.meshShaders.isNotEmpty ||
        scene.hasShadows ||
        scene.hasInstances ||
        scene.hasDeformation) {
      throw UnsupportedError(
        'Deformation, instancing, shadows and GPU programs require binary native submissions.',
      );
    }
    if (scene._textures.isNotEmpty) {
      throw UnsupportedError(
        'Texture materials require binary scene submissions.',
      );
    }
    return _freeze(<String, Object>{
          'version': 1,
          'view_projection': camera.viewProjection,
          'background': scene._background,
          'background_alpha': scene.backgroundOpacity,
          'light_direction': scene._light,
          'ambient': scene._ambient,
          'lights': scene._lights,
          'hemispheres': scene._hemispheres,
          if (colorPipeline case final pipeline?)
            'color_pipeline': {
              'tone_mapping': pipeline.toneMapping.index,
              'exposure': pipeline.exposure,
            },
          'geometries': [
            for (final id in {
              for (final mesh in scene._meshes) mesh['geometry'] as int,
            })
              if (!uploaded.contains(id)) scene._geometries[id]!.toNative(),
          ],
          'meshes': [
            for (final mesh in scene._meshes)
              Map<String, Object>.from(mesh)..remove('colorMap'),
          ],
        })
        as Map<String, Object>;
  }
}

Object _freeze(Object value) => switch (value) {
  Map<String, Object> map => Map<String, Object>.unmodifiable({
    for (final entry in map.entries) entry.key: _freeze(entry.value),
  }),
  List list => List<Object>.unmodifiable(
    list.map((item) => _freeze(item as Object)),
  ),
  _ => value,
};
