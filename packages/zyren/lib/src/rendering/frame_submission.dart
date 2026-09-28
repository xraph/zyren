import 'dart:typed_data';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../geometry/geometry.dart';
import '../geometry/vertex_attribute.dart';
import '../resources/texture_image.dart';
import '../resources/resource_scope.dart'
    show MaterialDevice, MeshShader, EnvironmentDevice, SpatialAntialiasing;
import '../scene/scene.dart';
import '../math/vec3.dart';
import 'frame_output.dart';
import 'depth_strategy.dart';
part 'scene_packet.dart';
part 'scene_draws.dart';

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
  final List<double> origin, viewProjection;
  final DepthStrategy depthStrategy;
  CameraSnapshot._(
    Iterable<double> origin,
    Iterable<double> viewProjection,
    this.depthStrategy,
  ) : origin = List.unmodifiable(origin),
      viewProjection = List.unmodifiable(viewProjection);
}

/// Captured transforms with shared immutable CPU geometry recipes.
class SceneSnapshot {
  final List<Map<String, Object>> _meshes;
  final Map<int, GeometrySnapshot> _geometries;
  final Map<int, TextureImage> _textures;
  final List<double> _background, _light;
  final double _ambient;
  final RenderSettings _settings;
  final List<List<double>> _lights, _shadows;
  final List<double> _shadowCamera;
  final List<double> _viewProjection;
  final DepthStrategy _depthStrategy;
  final SceneOutline? _outline;
  bool get hasOutline =>
      _outline != null && _meshes.any((m) => m['outlined'] == true);
  late final int drawCalls = _countDraws(this);
  int get triangles => _meshes.fold<int>(0, (sum, mesh) {
    final geometry = _geometries[mesh['geometry']]!;
    return sum +
        geometry.primitiveCount *
            math.max(1, (mesh['instances'] as List).length ~/ 16).toInt() *
            (geometry.topology == GeometryTopology.triangles ? 1 : 2);
  });
  SceneSnapshot._(
    this._meshes,
    this._geometries,
    this._textures,
    this._background,
    this._light,
    this._ambient,
    this._settings,
    this._lights,
    this._shadows,
    this._shadowCamera,
    this._viewProjection,
    this._depthStrategy,
    this._outline,
  );
  static SceneSnapshot _capture(
    Scene scene,
    Camera camera,
    List<double> viewProjection,
  ) {
    final meshes = <Map<String, Object>>[],
        geometries = <int, GeometrySnapshot>{};
    final textures = <int, TextureImage>{};
    final lights = <List<double>>[], shadows = <List<double>>[];
    final planes = <double>[
      for (final plane in scene.clippingPlanes) ...[
        ...plane.normal.storage,
        plane.normal.dot(camera.position) - plane.offset,
      ],
    ];
    if (planes.any(
      (value) => !value.isFinite || value.abs() > 3.4028234663852886e38,
    )) {
      throw ArgumentError(
        'Camera-relative clipping planes exceed the GPU numeric range.',
      );
    }
    void visit(
      Object3D node,
      vm.Matrix4 parent,
      bool parentVisible,
      bool parentClipping,
      bool parentOutlined,
      bool parentOutlineEnabled,
    ) {
      final visible = parentVisible && node.visible;
      final clipping = parentClipping && node.clippingEnabled;
      final outlineEnabled = parentOutlineEnabled && node.outlineEnabled;
      final outlined =
          outlineEnabled &&
          (parentOutlined || (scene.outline?.objects.contains(node) ?? false));
      final world = parent * node.localMatrix.toVectorMath();
      if (node is Light && visible) {
        final shadow = switch (node) {
          DirectionalLight l => l.shadow,
          SpotLight l => l.shadow,
          _ => null,
        };
        if (shadow != null) {
          if (node is HemisphereLight) {
            throw UnsupportedError('Hemisphere lights cannot cast shadows.');
          }
          shadows.add(
            List.unmodifiable([
              lights.length.toDouble(),
              shadow.resolution.toDouble(),
              shadow.cascades.toDouble(),
              shadow.near,
              shadow.maxDistance,
              shadow.bias,
              shadow.normalBias,
              shadow.splitLambda,
            ]),
          );
          if (shadows.fold(0.0, (sum, s) => sum + s[2]) > 8) {
            throw ArgumentError(
              'A view supports at most eight shadow projections.',
            );
          }
        }
        final direction = switch (node) {
          DirectionalLight light => light.direction,
          SpotLight light => light.direction,
          _ => const Vec3(0, 0, -1),
        };
        final vector = world.transform(
          vm.Vector4(direction.x, direction.y, direction.z, 0),
        );
        final d = vm.Vector3(vector.x, vector.y, vector.z)..normalize();
        final position =
            world.getTranslation() - camera.position.toVectorMath();
        final kind = node is HemisphereLight
            ? 3.0
            : node is SpotLight
            ? 2.0
            : node is PointLight
            ? 1.0
            : 0.0;
        lights.add(
          List.unmodifiable([
            ...position.storage,
            kind,
            ...node.color.toList(),
            node.intensity,
            ...d.storage,
            node is PointLight ? node.range : 0.0,
            node is SpotLight
                ? math.cos(node.angle * (1 - node.penumbra))
                : 0.0,
            node is SpotLight ? math.cos(node.angle) : 0.0,
            0.0,
            0.0,
            ...node is HemisphereLight
                ? node.groundColor.toList()
                : [0.0, 0.0, 0.0],
            0.0,
          ]),
        );
        if (lights.length > 16) {
          throw ArgumentError(
            'A scene supports at most sixteen physical lights.',
          );
        }
      }
      if (node is Mesh) {
        final shader = node.material is ShaderMaterial
            ? (node.material as ShaderMaterial).shader
            : null;
        if (shader != null &&
            shader.descriptor.requiresUv &&
            node.geometry.uv0 == null &&
            node.geometry.uv1 == null) {
          throw ArgumentError('This mesh shader requires UV attributes.');
        }
        if (node.castShadow &&
            (shader != null ||
                node.geometry.topology != GeometryTopology.triangles)) {
          throw UnsupportedError(
            'Shadow casters require triangle geometry with a built-in material.',
          );
        }
        final geometry = node.geometry.capture();
        geometries[geometry.id] = geometry;
        final map = node.material.colorMap;
        final standard = node.material is StandardMaterial
            ? node.material as StandardMaterial
            : null;
        final extraMaps = [
          standard?.normalMap,
          standard?.metallicRoughnessMap,
          standard?.occlusionMap,
          standard?.emissiveMap,
        ];
        final maps = [map, ...extraMaps].nonNulls;
        for (final entry in maps) {
          textures[entry.image.id] = entry.image;
        }
        if (visible) {
          for (final entry in maps) {
            if ((entry.uvSet == 0 ? node.geometry.uv0 : node.geometry.uv1) ==
                null) {
              throw ArgumentError(
                'Material map requires UV set ${entry.uvSet}.',
              );
            }
          }
        }
        if (visible) {
          final relative = world.clone()
            ..setTranslation(
              world.getTranslation() - camera.position.toVectorMath(),
            );
          if (clipping && planes.isNotEmpty && shader != null) {
            throw UnsupportedError(
              'Custom shader materials must opt out of scene clipping.',
            );
          }
          meshes.add(
            _freeze(<String, Object>{
                  'clippingPlanes': clipping ? planes : <double>[],
                  'outlined': outlined && (scene.outline?.opacity ?? 0) > 0,
                  'geometry': geometry.id,
                  'model': relative.storage.toList(),
                  'instances': node is InstancedMesh
                      ? [
                          for (var i = 0; i < node.count; i++)
                            ..._relativeInstance(
                              world,
                              node.transformAt(i).toVectorMath(),
                              camera.position,
                            ),
                        ]
                      : <double>[],
                  'color': node.material.color.toList(),
                  'unlit': node.material.unlit,
                  'side': node.material.side.index,
                  'shadowFlags':
                      (node.castShadow ? 1 : 0) | (node.receiveShadow ? 2 : 0),
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
                  'allImages': maps.map((entry) => entry.image.id).toList(),
                  'pbrMaps': [
                    for (final entry in extraMaps) ...[
                      entry == null ? 0 : 1,
                      ...?entry?.toPacket(),
                    ],
                  ],
                  'pbrScales': [
                    standard?.normalScaleX ?? 1.0,
                    standard?.normalScaleY ?? 1.0,
                    standard?.occlusionStrength ?? 1.0,
                  ],
                  'shader': ?shader,
                  'pbr': node.material is StandardMaterial
                      ? [
                          (node.material as StandardMaterial).metallic,
                          (node.material as StandardMaterial).roughness,
                          (node.material as StandardMaterial).emissiveIntensity,
                          ...(node.material as StandardMaterial).emissive
                              .toList(),
                        ]
                      : <double>[],
                })
                as Map<String, Object>,
          );
        }
      }
      for (final child in node.children) {
        visit(child, world, visible, clipping, outlined, outlineEnabled);
      }
    }

    visit(scene, vm.Matrix4.identity(), true, true, false, true);
    return SceneSnapshot._(
      List.unmodifiable(meshes),
      Map.unmodifiable(geometries),
      Map.unmodifiable(textures),
      List.unmodifiable(scene.background.toList()),
      List.unmodifiable(scene.lightDirection.storage),
      scene.ambient,
      scene.renderSettings.copyWith(
        backgroundAlpha: scene.backgroundAlpha,
        effects: scene.effects,
        environment: scene.environment,
        hdr:
            scene.renderSettings.hdr ||
            meshes.any((m) => (m['pbr'] as List).isNotEmpty) ||
            lights.isNotEmpty,
      ),
      List.unmodifiable(lights),
      List.unmodifiable(shadows),
      List.unmodifiable(switch (camera) {
        PerspectiveCamera c => [c.near, c.far],
        OrthographicCamera c => [c.near, c.far],
        _ =>
          shadows.isEmpty
              ? [.1, 1000.0]
              : throw UnsupportedError(
                  'Shadows require a perspective or orthographic camera.',
                ),
      }),
      viewProjection,
      camera.depthStrategy,
      scene.outline,
    );
  }
}

class FrameSubmission {
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
  );

  /// Captures once so changes made during an asynchronous render affect only
  /// later submissions. This does not allocate a GPU or require Flutter.
  factory FrameSubmission.capture({
    required Scene scene,
    required Camera camera,
    required PhysicalSize size,
    OutputTarget target = const ReadbackTarget(),
    FrameTime time = const FrameTime(),
  }) {
    final clock = Stopwatch()..start();

    final cameraSnapshot = CameraSnapshot._(
      camera.position.storage,
      camera.viewProjection(size.width / size.height).storage,
      camera.depthStrategy,
    );
    final sceneSnapshot = SceneSnapshot._capture(
      scene,
      camera,
      cameraSnapshot.viewProjection,
    );
    return FrameSubmission._(
      sceneSnapshot,
      cameraSnapshot,
      target,
      size,
      time,
      clock.elapsed,
    );
  }

  /// Compatibility encoder for native v1 adapters. Geometry conversion is lazy.
  Map<String, Object> toNativePacket({Set<int> uploaded = const {}}) {
    if (scene.hasOutline ||
        camera.depthStrategy != DepthStrategy.standard ||
        scene._settings.enabled ||
        scene._textures.isNotEmpty ||
        scene._meshes.any(
          (m) =>
              m.containsKey('shader') ||
              (m['clippingPlanes'] as List).isNotEmpty ||
              m['shadowFlags'] != 2 ||
              (m['instances'] as List).isNotEmpty,
        )) {
      throw UnsupportedError('This frame requires binary scene submissions.');
    }
    return _freeze(<String, Object>{
          'version': 1,
          'view_projection': camera.viewProjection,
          'background': scene._background,
          'light_direction': scene._light,
          'ambient': scene._ambient,
          'geometries': [
            for (final id in {
              for (final mesh in scene._meshes) mesh['geometry'] as int,
            })
              if (!uploaded.contains(id)) scene._geometries[id]!.toNative(),
          ],
          'meshes': [
            for (final mesh in scene._meshes)
              Map<String, Object>.from(mesh)
                ..remove('colorMap')
                ..remove('pbr')
                ..remove('pbrMaps')
                ..remove('pbrScales')
                ..remove('allImages')
                ..remove('shadowFlags')
                ..remove('instances')
                ..remove('clippingPlanes')
                ..remove('outlined'),
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

List<double> _relativeInstance(
  vm.Matrix4 parent,
  vm.Matrix4 instance,
  Vec3 origin,
) {
  final world = parent * instance;
  world.setTranslation(world.getTranslation() - origin.toVectorMath());
  return world.storage.toList();
}
