import 'dart:typed_data';
import 'color_pipeline.dart';
import 'temporal_aa_options.dart';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../geometry/geometry.dart';
import '../geometry/vertex_attribute.dart';
import '../resources/texture_image.dart';
import '../scene/scene.dart';
import '../math/mat4.dart';
import '../spatial/frustum.dart';
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
  final List<double> origin, viewProjection, projection, forward;
  final int identity;
  final double targetDistance;
  CameraSnapshot._(
    Iterable<double> origin,
    Iterable<double> viewProjection,
    Iterable<double> projection,
    Iterable<double> forward,
    this.identity,
    this.targetDistance,
  ) : forward = List.unmodifiable(forward),
      origin = List.unmodifiable(origin),
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
  final List<(int, int)> _identities;
  final List<Map<String, Object>> _lights, _hemispheres, _areas;
  bool get hasStandardMaterials => _meshes.any((m) => m.containsKey('pbr'));
  int get punctualLightCount => _lights.length;
  int get areaLightCount => _areas.length;
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
  bool _transmissive(Map<String, Object> mesh) {
    final pbr = mesh['pbr'] as Map?;
    return pbr != null &&
        ((pbr['transmission'] as List?)?.first as num? ?? 0) > 0 &&
        ((pbr['metallic'] as num) < 1 || pbr['metallic_roughness_map'] != null);
  }

  bool get hasTransmission =>
      _meshes.any((m) => m['color_visible'] != false && _transmissive(m));
  int get transmissionCaptureDraws => hasTransmission
      ? _meshes
            .where(
              (m) =>
                  m['color_visible'] != false &&
                  m['alpha_mode'] != 2 &&
                  !_transmissive(m),
            )
            .length
      : 0;
  int get drawCalls => _meshes.fold(
    0,
    (n, mesh) =>
        n +
        (mesh['color_visible'] == false
            ? 0
            : mesh['alpha_mode'] == 2
            ? mesh['instance_count'] as int
            : 1),
  );

  /// Motion draws batch each visible mesh, including transparent instances.
  int get temporalMotionDraws =>
      _meshes.where((mesh) => mesh['color_visible'] != false).length;
  int get transmissionCaptureTriangles => !hasTransmission
      ? 0
      : _meshes.fold(0, (sum, mesh) {
          if (mesh['color_visible'] == false ||
              mesh['alpha_mode'] == 2 ||
              _transmissive(mesh)) {
            return sum;
          }
          final geometry = _geometries[mesh['geometry']]!;
          return sum +
              (mesh['instance_count'] as int) *
                  geometry.primitiveCount *
                  (geometry.topology == GeometryTopology.triangles ? 1 : 2);
        });
  int get triangles => _meshes.fold(0, (sum, mesh) {
    if (mesh['color_visible'] == false) return sum;
    final geometry = _geometries[mesh['geometry']]!;
    return sum +
        (mesh['instance_count'] as int) *
            geometry.primitiveCount *
            (geometry.topology == GeometryTopology.triangles ? 1 : 2);
  });
  SceneSnapshot._(
    this._meshes,
    this._identities,
    this._lights,
    this._hemispheres,
    this._areas,
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
  static SceneSnapshot _capture(Scene scene, Camera camera, Frustum frustum) {
    final meshes = <Map<String, Object>>[],
        geometries = <int, GeometrySnapshot>{};
    final textures = <int, TextureImage>{};
    final instances = <int, InstanceSnapshot>{};
    final poses = <int, DeformationSnapshot>{};
    var instanceCapacity = 0;
    final lights = <Map<String, Object>>[];
    final hemispheres = <Map<String, Object>>[];
    final areas = <Map<String, Object>>[];
    final identities = <(int, int)>[];
    final meshShaders = <int, MeshShaderProgram>{};
    final shadows = <_ShadowLight>[];
    void visit(Object3D node, vm.Matrix4 parent, bool parentVisible) {
      final visible = parentVisible && node.visible;
      final matchesLayers = node.layers.intersects(camera.layers);
      final world = parent * node.localMatrix.toVectorMath();
      if (visible && matchesLayers && node is RectAreaLight) {
        if (areas.length >= 4) {
          throw ArgumentError(
            'A scene supports at most 4 visible area lights.',
          );
        }
        final w =
            vm.Vector3(
              world.entry(0, 0),
              world.entry(1, 0),
              world.entry(2, 0),
            ) *
            (node.width * .5);
        final h =
            vm.Vector3(
              world.entry(0, 1),
              world.entry(1, 1),
              world.entry(2, 1),
            ) *
            (node.height * .5);
        final area = w.cross(h).length2;
        if (!area.isFinite || area < 1e-20) {
          throw ArgumentError(
            'Area light transform must define a finite nonzero area.',
          );
        }
        areas.add(
          _freeze(<String, Object>{
                'position':
                    (world.getTranslation() - camera.position.toVectorMath())
                        .storage
                        .toList(),
                'half_width': w.storage.toList(),
                'half_height': h.storage.toList(),
                'color': node.color.toList(),
                'intensity': node.intensity,
              })
              as Map<String, Object>,
        );
      }
      if (visible && matchesLayers && node is HemisphereLight) {
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
      if (visible && matchesLayers && node is PunctualLight) {
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
        if (visible &&
            matchesLayers &&
            (node is! InstancedMesh || node.count > 0)) {
          if (node.material.vertexColors && geometry.colors == null) {
            throw ArgumentError('Vertex colors require a color attribute.');
          }
          if (node.material case ShaderMaterial(:final program)) {
            if (program.geometry.usesInstancing != (instance != null) ||
                program.geometry.usesDeformation != (pose != null)) {
              throw ArgumentError(
                'Mesh shader geometry profile ${program.geometry.name} '
                'does not match this mesh.',
              );
            }
            if (program.isClosed) {
              throw StateError('Mesh shader has closed: ${program.label}');
            }
            if (program.vertexLayout.hasUv &&
                node.geometry.uv0 == null &&
                node.geometry.uv1 == null) {
              throw ArgumentError('This mesh shader requires UV attributes.');
            }
            if (program.vertexLayout.hasTangents && geometry.tangents == null) {
              throw ArgumentError(
                'This mesh shader requires tangent attributes.',
              );
            }
            if (program.vertexLayout.hasColors && geometry.colors == null) {
              throw ArgumentError(
                'This mesh shader requires color attributes.',
              );
            }
            meshShaders[meshes.length] = program;
          }
          if (node.material case PhysicalMaterial(:final anisotropy)) {
            if (anisotropy > 0 && geometry.tangents == null) {
              throw ArgumentError('Anisotropy requires geometry tangents.');
            }
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
          final bounds =
              node.cullingBounds ??
              (node.material is! ShaderMaterial &&
                      geometry.topology == GeometryTopology.triangles
                  ? node.bounds
                  : null);
          final colorVisible =
              !node.frustumCulled ||
              frustum.intersectsBounds(
                bounds?.transformed(Mat4.fromVectorMath(relative)),
              );
          identities.add((node.id, geometry.logicalId));
          meshes.add(
            _freeze(<String, Object>{
                  'color_visible': colorVisible,
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
                      if (material is PhysicalMaterial) ...{
                        if (material.clearcoatMap != null)
                          'clearcoat_map': material.clearcoatMap!.toPacket(),
                        if (material.clearcoatRoughnessMap != null)
                          'clearcoat_roughness_map': material
                              .clearcoatRoughnessMap!
                              .toPacket(),
                        if (material.clearcoatNormalMap != null)
                          'clearcoat_normal_map': material.clearcoatNormalMap!
                              .toPacket(),
                        if (material.sheenColorMap != null)
                          'sheen_color_map': material.sheenColorMap!.toPacket(),
                        if (material.sheenRoughnessMap != null)
                          'sheen_roughness_map': material.sheenRoughnessMap!
                              .toPacket(),
                        if (material.specularIntensityMap != null)
                          'specular_intensity_map': material
                              .specularIntensityMap!
                              .toPacket(),
                        if (material.specularColorMap != null)
                          'specular_color_map': material.specularColorMap!
                              .toPacket(),
                        if (material.anisotropyMap != null)
                          'anisotropy_map': material.anisotropyMap!.toPacket(),
                        if (material.transmissionMap != null)
                          'transmission_map': material.transmissionMap!
                              .toPacket(),
                        if (material.thicknessMap != null)
                          'thickness_map': material.thicknessMap!.toPacket(),
                        if (material.iridescenceMap != null)
                          'iridescence_map': material.iridescenceMap!
                              .toPacket(),
                        if (material.iridescenceThicknessMap != null)
                          'iridescence_thickness_map': material
                              .iridescenceThicknessMap!
                              .toPacket(),
                        'optical': <double>[
                          material.iridescence,
                          material.iridescenceIor,
                          material.iridescenceThicknessMinimum,
                          material.iridescenceThicknessMaximum,
                          material.dispersion,
                          0,
                          0,
                          0,
                        ],
                        'transmission': <double>[
                          material.transmission,
                          material.thickness,
                          material.attenuationDistance.isInfinite
                              ? 0
                              : material.attenuationDistance,
                          0,
                          ...material.attenuationColor.toList(),
                          0,
                        ],
                        'physical': <double>[
                          material.ior,
                          material.specularIntensity,
                          material.clearcoat,
                          material.clearcoatRoughness,
                          ...material.specularColor.toList(maxChannel: 1e6),
                          material.sheenRoughness,
                          ...material.sheenColor.toList(),
                          material.anisotropy,
                          material.anisotropyRotation,
                          1,
                          material.clearcoatNormalScale,
                          0,
                        ],
                      },
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
      List.unmodifiable(identities),
      List.unmodifiable(lights),
      List.unmodifiable(hemispheres),
      List.unmodifiable(areas),
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
  /// A graph already counts its final output conversion. Standalone HDR needs one.
  int get outputConversionDraws =>
      colorPipeline != null && graph == null ? 1 : 0;
  final ShadowSnapshot shadows;
  final CompiledGraph? graph;
  final ColorPipeline? colorPipeline;
  final TemporalAAOptions? temporalAA;
  final int temporalReset;
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
    this.temporalAA,
    this.temporalReset,
    this.environment,
    this.shadows,
  );

  /// Captures once so changes made during an asynchronous render affect only
  /// later submissions. This does not allocate a GPU or require Flutter.
  /// [aspectRatio] preserves the logical viewport when physical pixels round.
  /// Without it, the projection follows [size].
  factory FrameSubmission.capture({
    required Scene scene,
    required Camera camera,
    required PhysicalSize size,
    double? aspectRatio,
    OutputTarget target = const ReadbackTarget(),
    FrameTime time = const FrameTime(),
    CompiledGraph? graph,
    ColorPipeline? colorPipeline,
    TemporalAAOptions? temporalAA,
    int temporalReset = 0,
    Environment? environment,
  }) {
    if (temporalReset < 0 ||
        temporalReset > 0x1fffffffffffff ||
        (temporalAA != null &&
            (colorPipeline == null || colorPipeline.sampleCount != 1))) {
      throw ArgumentError(
        'Temporal AA needs single-sample HDR and a nonnegative safe reset generation.',
      );
    }
    final clock = Stopwatch()..start();
    final aspect = aspectRatio ?? size.width / size.height;

    final cameraSnapshot = CameraSnapshot._(
      camera.position.storage,
      camera.viewProjection(aspect).storage,
      camera.projectionMatrix(aspect).storage,
      (camera.target - camera.position).normalized().storage,
      camera.id,
      camera.target.distanceTo(camera.position),
    );
    final sceneSnapshot = SceneSnapshot._capture(
      scene,
      camera,
      Frustum.fromMatrix(Mat4(cameraSnapshot.viewProjection)),
    );
    return FrameSubmission._(
      sceneSnapshot,
      cameraSnapshot,
      target,
      size,
      time,
      clock.elapsed,
      graph,
      colorPipeline,
      temporalAA,
      temporalReset,
      environment,
      ShadowSnapshot.capture(sceneSnapshot, camera, aspect),
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
    temporalAA,
    temporalReset,
    environment,
    shadows,
  );

  /// Compatibility encoder for native v1 adapters. Geometry conversion is lazy.
  Map<String, Object> toNativePacket({Set<int> uploaded = const {}}) {
    if (temporalAA != null ||
        graph != null ||
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
          if (scene._areas.isNotEmpty) 'areas': scene._areas,
          if (colorPipeline case final pipeline?)
            'color_pipeline': {
              'tone_mapping': pipeline.toneMapping.index,
              'exposure': pipeline.exposure,
              if (pipeline.sampleCount != 1)
                'sample_count': pipeline.sampleCount,
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
