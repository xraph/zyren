/// Runtime scene construction from compiled game data, without an editor.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';

/// A host retains imported bytes and animation data until the runtime is closed.
final class GameSceneAsset {
  final Object3D root;
  final Future<void> Function() close;
  GameSceneAsset({required this.root, required this.close});
}

typedef GameSceneAssetLoader =
    Future<GameSceneAsset> Function(
      GameAssetReference reference,
      LoadCancellation cancellation,
    );

/// Owns imported resource leases. Dispose the scene engine before closing it.
final class GameRuntimeScene {
  final Scene scene;
  final PerspectiveCamera camera;
  final Map<String, Object3D> objects;
  final List<GameSceneAsset> _assets;
  Future<void>? _closing;
  GameRuntimeScene._(
    this.scene,
    this.camera,
    Map<String, Object3D> objects,
    this._assets,
  ) : objects = Map.unmodifiable(objects);

  static Future<GameRuntimeScene> load(
    CompiledGameProject project, {
    String? levelId,
    GameSceneAssetLoader? loadAsset,
    LoadCancellation? cancellation,
  }) async {
    final token = cancellation ?? LoadCancellationSource();
    token.throwIfCancelled();
    final level = levelId ?? project.project.startupLevel;
    if (!project.levels.any((value) => value.id == level)) {
      throw StateError('Compiled level is missing.');
    }
    final nodes = project.sceneNodes[level];
    if (nodes == null) throw StateError('Compiled scene is missing.');
    final recipes = <String, _Node>{};
    for (final json in nodes) {
      final node = _Node(json);
      if (recipes.containsKey(node.id)) {
        throw const FormatException('Compiled scene node IDs must be unique.');
      }
      recipes[node.id] = node;
    }
    for (final node in recipes.values) {
      final visited = <String>{node.id};
      var parent = node.parent;
      while (parent != null) {
        if (!visited.add(parent) || !recipes.containsKey(parent)) {
          throw const FormatException(
            'Compiled scene parent is missing or cyclic.',
          );
        }
        parent = recipes[parent]!.parent;
      }
      if (node.kind == 'asset') {
        final ref = node.asset!;
        if (!project.assets.any(
          (pin) =>
              pin.id == ref.id &&
              pin.revision == ref.revision &&
              pin.uri == ref.uri &&
              pin.digest == ref.digest,
        )) {
          throw StateError('Scene asset differs from compiled project pins.');
        }
        if (loadAsset == null) {
          throw StateError('Scene requires an asset loader.');
        }
      }
    }
    final scene = Scene();
    final camera = PerspectiveCamera(
      position: const Vec3(0, 4, -8),
      target: Vec3.zero,
    );
    final objects = <String, Object3D>{};
    final leases = <GameSceneAsset>[];
    try {
      for (final node in recipes.values) {
        token.throwIfCancelled();
        final object = Group(name: node.label);
        if (node.kind == 'asset') {
          final asset = await loadAsset!(node.asset!, token);
          leases.add(asset);
          token.throwIfCancelled();
          if (asset.root.parent != null) {
            throw StateError('Imported asset must be a fresh instance.');
          }
          object.add(asset.root);
          if (node.material != null) {
            final pending = <Object3D>[asset.root];
            while (pending.isNotEmpty) {
              final child = pending.removeLast();
              pending.addAll(child.children);
              if (child is Mesh) {
                child.material = node.material!.create(
                  imported: child.material,
                );
              }
            }
          }
        } else if (node.kind != 'group' && node.kind != 'prefab') {
          object.add(
            Mesh(
              _geometry(node.kind),
              (node.material ?? _Material({'color': node.color})).create(),
            )..scale = node.size,
          );
        }
        object.position = node.position;
        object.scale = node.scale;
        object.quaternion = node.rotation;
        object.visible = node.visible;
        objects[node.id] = object;
      }
      for (final node in recipes.values) {
        (objects[node.parent] ?? scene).add(objects[node.id]!);
      }
      return GameRuntimeScene._(scene, camera, objects, leases);
    } catch (error, stack) {
      for (final lease in leases.reversed) {
        try {
          await lease.close();
        } catch (_) {
          // Retire every acquired lease while preserving the load failure.
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    Object? error;
    StackTrace? stack;
    for (final asset in _assets.reversed) {
      try {
        await asset.close();
      } catch (e, s) {
        error ??= e;
        stack ??= s;
      }
    }
    _assets.clear();
    if (error != null) Error.throwWithStackTrace(error, stack!);
  }
}

BufferGeometry _geometry(String kind) => switch (kind) {
  'box' => BoxGeometry(),
  'sphere' => SphereGeometry(radius: .5),
  'cylinder' => CylinderGeometry(radiusTop: .5, radiusBottom: .5),
  'cone' => ConeGeometry(radius: .5),
  'torus' => TorusGeometry(radius: .35, tube: .15),
  'plane' => PlaneGeometry(),
  _ => throw FormatException('Unsupported scene primitive $kind.'),
};

final class _Node {
  final String id, label, kind;
  final String? parent;
  final Vec3 position, scale, size;
  final Quat rotation;
  final bool visible;
  final int color;
  final _Material? material;
  final GameAssetReference? asset;
  _Node(Map<String, Object?> data)
    : id = _text(data['id']),
      label = _text(data['label']),
      kind = _text(data['kind']),
      parent = data['parentId'] == null ? null : _text(data['parentId']),
      position = _vector(data['position']),
      scale = _vector(data['scale']),
      size = _vector(data['size']),
      rotation = _rotation(data['rotation']),
      visible = data['visible'] as bool,
      color = _color(data['color']),
      material = data['material'] == null
          ? null
          : _Material(Map<String, Object?>.from(data['material'] as Map)),
      asset = data['assetReference'] == null
          ? null
          : GameAssetReference.fromJson(
              Map<String, Object?>.from(data['assetReference'] as Map),
            ) {
    if (!{
          'group',
          'prefab',
          'box',
          'sphere',
          'cylinder',
          'cone',
          'torus',
          'plane',
          'asset',
        }.contains(kind) ||
        scale.x == 0 ||
        scale.y == 0 ||
        scale.z == 0 ||
        size.x <= 0 ||
        size.y <= 0 ||
        size.z <= 0 ||
        (kind == 'asset') != (asset != null)) {
      throw const FormatException('Invalid compiled scene node.');
    }
  }
}

String _text(Object? value) {
  if (value is! String || value.isEmpty || value.length > 1024) {
    throw const FormatException('Invalid scene identity.');
  }
  return value;
}

Vec3 _vector(Object? value) {
  if (value is! List || value.length != 3) {
    throw const FormatException('Invalid scene vector.');
  }
  final result = Vec3(
    (value[0] as num).toDouble(),
    (value[1] as num).toDouble(),
    (value[2] as num).toDouble(),
  );
  if (!result.isFinite) throw const FormatException('Non-finite scene vector.');
  return result;
}

Quat _rotation(Object? value) {
  if (value is! List ||
      value.length != 4 ||
      value.any((v) => v is! num || !v.isFinite)) {
    throw const FormatException('Invalid scene rotation.');
  }
  final q = Quat(
    (value[0] as num).toDouble(),
    (value[1] as num).toDouble(),
    (value[2] as num).toDouble(),
    (value[3] as num).toDouble(),
  );
  return q.normalized();
}

int _color(Object? value) {
  if (value is! int || value < 0 || value > 0xffffff) {
    throw const FormatException('Invalid scene color.');
  }
  return value;
}

final class _Material {
  final Map<String, Object?> data;
  _Material(this.data) {
    if (!{'diffuse', 'unlit', 'standard'}.contains(data['kind'] ?? 'diffuse')) {
      throw const FormatException('Unsupported game material.');
    }
    _color(data['color']);
    _color(data['emissive'] ?? 0);
    for (final key in ['opacity', 'metallic', 'roughness']) {
      final value = data[key];
      if (value != null &&
          (value is! num || !value.isFinite || value < 0 || value > 1)) {
        throw const FormatException('Invalid material range.');
      }
    }
    final intensity = data['emissiveIntensity'] ?? 1;
    if (intensity is! num ||
        !intensity.isFinite ||
        intensity < 0 ||
        intensity > 1000) {
      throw const FormatException('Invalid emissive intensity.');
    }
  }
  MeshMaterial create({MeshMaterial? imported}) {
    final opacity = (data['opacity'] as num? ?? 1).toDouble();
    final side = data['doubleSided'] == true
        ? MaterialSide.doubleSided
        : MaterialSide.front;
    final alpha = opacity < 1
        ? MaterialAlphaMode.blend
        : MaterialAlphaMode.opaque;
    final color = Color3.hex(_color(data['color']));
    return switch (data['kind'] ?? 'diffuse') {
      'unlit' => UnlitMaterial(
        color: color,
        colorMap: imported?.colorMap,
        opacity: opacity,
        alphaMode: alpha,
        side: side,
      ),
      'standard' =>
        (imported is StandardMaterial
                ? imported
                : StandardMaterial(colorMap: imported?.colorMap))
            .copyWith(
              color: color,
              metallic: (data['metallic'] as num? ?? 0).toDouble(),
              roughness: (data['roughness'] as num? ?? .7).toDouble(),
              emissive: Color3.hex(_color(data['emissive'] ?? 0)),
              emissiveIntensity: (data['emissiveIntensity'] as num? ?? 1)
                  .toDouble(),
              opacity: opacity,
              alphaMode: alpha,
              side: side,
            ),
      _ => DiffuseMaterial(
        color: color,
        colorMap: imported?.colorMap,
        opacity: opacity,
        alphaMode: alpha,
        side: side,
      ),
    };
  }
}
