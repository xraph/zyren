part of '../../zyren_game.dart';

/// Hard ceilings can be reduced for a host, but never increased.
final class GameLimits {
  static const maxSourceBytes = 16 * 1024 * 1024;
  static const maxJsonDepth = 32;
  static const maxJsonNodes = 4096;
  static const maxJsonStringBytes = 65536;
  final int maxEntities, maxComponentsPerEntity, maxQueuedCommands;
  final int maxComponentTypes, maxLevels;

  GameLimits({
    this.maxEntities = 10000,
    this.maxComponentsPerEntity = 64,
    this.maxQueuedCommands = 4096,
    this.maxComponentTypes = 1024,
    this.maxLevels = 256,
  }) {
    _limit(maxEntities, 10000, 'maxEntities');
    _limit(maxComponentsPerEntity, 64, 'maxComponentsPerEntity');
    _limit(maxQueuedCommands, 4096, 'maxQueuedCommands');
    _limit(maxComponentTypes, 1024, 'maxComponentTypes');
    _limit(maxLevels, 256, 'maxLevels');
  }
}

void _limit(int value, int ceiling, String name) {
  if (value < 1 || value > ceiling) {
    throw RangeError.range(value, 1, ceiling, name);
  }
}

String _id(String value) {
  if (value.isEmpty || value.trim() != value || value.length > 1024) {
    throw const FormatException(
      'IDs must contain 1 to 1024 unpadded characters.',
    );
  }
  return value;
}

Map<String, Object?> _json(Map<String, Object?> value) {
  var nodes = 0;
  final active = HashSet<Object>.identity();
  Object? freeze(Object? item, int depth) {
    if (++nodes > GameLimits.maxJsonNodes || depth > GameLimits.maxJsonDepth) {
      throw const FormatException('JSON exceeds node or depth limits.');
    }
    if (item == null || item is bool || item is int) return item;
    if (item is String) {
      if (item.length > GameLimits.maxJsonStringBytes ||
          utf8.encode(item).length > GameLimits.maxJsonStringBytes) {
        throw const FormatException('JSON string exceeds byte limit.');
      }
      return item;
    }
    if (item is double && item.isFinite) return item;
    if (item is List || item is Map) {
      if (!active.add(item)) throw const FormatException('Cyclic JSON.');
      try {
        if (item is List) {
          if (item.length > GameLimits.maxJsonNodes) {
            throw const FormatException('JSON list exceeds limit.');
          }
          return List<Object?>.unmodifiable(
            item.map((v) => freeze(v, depth + 1)),
          );
        }
        final map = item as Map;
        if (map.length > GameLimits.maxJsonNodes) {
          throw const FormatException('JSON map exceeds limit.');
        }
        final result = <String, Object?>{};
        for (final entry in map.entries) {
          if (entry.key is! String) {
            throw const FormatException('Non-string JSON key.');
          }
          final key = freeze(entry.key, depth + 1) as String;
          result[key] = freeze(entry.value, depth + 1);
        }
        return Map<String, Object?>.unmodifiable(result);
      } finally {
        active.remove(item);
      }
    }
    throw const FormatException(
      'Component data must contain finite JSON values.',
    );
  }

  return freeze(value, 0) as Map<String, Object?>;
}

Map<String, Object?> _map(Object? value) {
  if (value is! Map<String, Object?>) {
    throw const FormatException('Expected JSON object.');
  }
  return value;
}

String _string(Object? value) {
  if (value is! String) throw const FormatException('Expected string.');
  return value;
}

int _integer(Object? value) {
  if (value is! int) throw const FormatException('Expected integer.');
  return value;
}

List<Object?> _list(Object? value) {
  if (value is! List<Object?>) throw const FormatException('Expected array.');
  return value;
}

/// Authored data stays immutable, including unregistered required components.
final class GameComponentRecord {
  final String type;
  final int version;
  final Map<String, Object?> data;
  final bool required;

  GameComponentRecord(
    String type,
    this.version,
    Map<String, Object?> data, {
    this.required = true,
  }) : type = _id(type),
       data = _json(data) {
    if (version < 1) {
      throw const FormatException('Component versions start at one.');
    }
  }

  Map<String, Object?> toJson() => {
    'type': type,
    'version': version,
    'required': required,
    'data': data,
  };

  factory GameComponentRecord.fromJson(Map<String, Object?> value) {
    final required = value['required'] ?? true;
    if (required is! bool) {
      throw const FormatException('Expected required boolean.');
    }
    return GameComponentRecord(
      _string(value['type']),
      _integer(value['version']),
      _map(value['data']),
      required: required,
    );
  }
}

/// A codec names the JSON field that contains a local entity ID.
/// Path segments are map keys or list indices, so unrelated strings are untouched.
final class GameLocalReference {
  final List<Object> path;
  final String targetId;
  GameLocalReference(List<Object> path, String targetId)
    : path = List.unmodifiable(path),
      targetId = _id(targetId) {
    if (path.isEmpty ||
        path.length > GameLimits.maxJsonDepth ||
        path.any((v) => v is! String && v is! int || v is int && v < 0)) {
      throw const FormatException('Invalid local reference path.');
    }
  }
}

abstract class GameComponentCodec<T extends Object> {
  String get type;
  int get version;
  void validate(Map<String, Object?> data);

  /// Convert an older record directly to [version], or throw if unsupported.
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data);
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data);
  T factory(Map<String, Object?> data);
}
