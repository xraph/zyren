import 'dart:typed_data';
import 'dart:math' as math;
import 'package:vector_math/vector_math_64.dart' as vm;
import '../geometry/geometry.dart';
import '../geometry/vertex_attribute.dart';
import '../resources/texture_image.dart';
import '../resources/resource_scope.dart'
    show MaterialDevice, MeshShader, EnvironmentDevice;
import '../scene/scene.dart';
import '../math/vec3.dart';
import 'frame_output.dart';
part 'scene_packet.dart';

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
  CameraSnapshot._(Iterable<double> origin, Iterable<double> viewProjection)
    : origin = List.unmodifiable(origin),
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
  final List<List<double>> _lights;
  int get drawCalls => _meshes.length;
  int get triangles => _meshes.fold(0, (sum, mesh) {
    final geometry = _geometries[mesh['geometry']]!;
    return sum +
        geometry.primitiveCount *
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
  );
  static SceneSnapshot _capture(Scene scene, Camera camera) {
    final meshes = <Map<String, Object>>[],
        geometries = <int, GeometrySnapshot>{};
    final textures = <int, TextureImage>{};
    final lights = <List<double>>[];
    void visit(Object3D node, vm.Matrix4 parent, bool parentVisible) {
      final visible = parentVisible && node.visible;
      final world = parent * node.localMatrix.toVectorMath();
      if (node is Light && visible) {
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
          meshes.add(
            _freeze(<String, Object>{
                  'geometry': geometry.id,
                  'model': relative.storage.toList(),
                  'color': node.material.color.toList(),
                  'unlit': node.material.unlit,
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
        visit(child, world, visible);
      }
    }

    visit(scene, vm.Matrix4.identity(), true);
    return SceneSnapshot._(
      List.unmodifiable(meshes),
      Map.unmodifiable(geometries),
      Map.unmodifiable(textures),
      List.unmodifiable(scene.background.toList()),
      List.unmodifiable(scene.lightDirection.storage),
      scene.ambient,
      scene.renderSettings.copyWith(
        effects: scene.effects,
        environment: scene.environment,
        hdr:
            scene.renderSettings.hdr ||
            meshes.any((m) => (m['pbr'] as List).isNotEmpty) ||
            lights.isNotEmpty,
      ),
      List.unmodifiable(lights),
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
    );
    final sceneSnapshot = SceneSnapshot._capture(scene, camera);
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
    if (scene._settings.enabled ||
        scene._textures.isNotEmpty ||
        scene._meshes.any((m) => m.containsKey('shader'))) {
      throw UnsupportedError(
        'Texture materials require binary scene submissions.',
      );
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
                ..remove('allImages'),
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
