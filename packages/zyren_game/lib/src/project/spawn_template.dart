part of '../../zyren_game.dart';

/// A flat compiled runtime recipe. Studio owns authored prefab expansion.
final class GameSpawnTemplate {
  final String id;
  final List<GameEntityRecord> entities;
  final GameRegistry registry;
  final Object _identity = Object();
  factory GameSpawnTemplate({
    required String id,
    required List<GameEntityRecord> entities,
    required GameRegistry registry,
  }) {
    final frozen = registry.snapshot();
    return GameSpawnTemplate._(
      _id(id),
      _validateEntities(entities, frozen),
      frozen,
    );
  }
  GameSpawnTemplate._(this.id, this.entities, this.registry);

  List<GameEntityRecord> instantiate(String instanceId) {
    _id(instanceId);
    final instanceMap = <String, String>{
      for (final entity in entities) entity.id: _id('$instanceId/${entity.id}'),
    };
    // All IDs exist before any reference is rewritten or any factory can run.
    final result = entities
        .map(
          (entity) => GameEntityRecord(
            id: instanceMap[entity.id]!,
            nodeId: entity.nodeId,
            components: entity.components.map((component) {
              if (!registry.supports(component)) {
                if (component.required) {
                  throw StateError(
                    'Unsupported required component: ${component.type}.',
                  );
                }
                return component;
              }
              Object? data = component.data;
              for (final reference in registry.references(component)) {
                data = _replacePath(
                  data,
                  reference.path,
                  0,
                  instanceMap[reference.targetId]!,
                );
              }
              final mapped = GameComponentRecord(
                component.type,
                component.version,
                _map(data),
                required: component.required,
              );
              registry.normalize(mapped);
              return mapped;
            }).toList(),
          ),
        )
        .toList();
    return List.unmodifiable(
      result.map((e) => GameEntityRecord._instantiated(e, _identity)),
    );
  }

  /// Accepts only an entity produced by this template's [instantiate] call.
  List<Object> construct(GameEntityRecord entity) {
    if (!identical(entity._spawnOrigin, _identity)) {
      throw StateError(
        'Instantiate this template before constructing components.',
      );
    }
    final components = entity.components.map(registry.normalize).toList();
    for (final component in components) {
      if (component.required && !registry.supports(component)) {
        throw StateError('Unsupported required component: ${component.type}.');
      }
    }
    return List.unmodifiable([
      for (final component in components)
        if (registry.construct(component) case final Object value) value,
    ]);
  }
}

Object? _replacePath(
  Object? data,
  List<Object> path,
  int index,
  String target,
) {
  if (index == path.length) return target;
  final segment = path[index];
  if (segment is String &&
      data is Map<String, Object?> &&
      data.containsKey(segment)) {
    final result = Map<String, Object?>.of(data);
    result[segment] = _replacePath(data[segment], path, index + 1, target);
    return result;
  }
  if (segment is int && data is List<Object?> && segment < data.length) {
    final result = List<Object?>.of(data);
    result[segment] = _replacePath(data[segment], path, index + 1, target);
    return result;
  }
  throw const FormatException('Cannot remap local reference path.');
}
