import 'dart:convert';
import 'package:zyren/zyren.dart';

const maxSceneRevision = 9007199254740991;

/// Source-owned identity. Neither display names nor runtime object IDs are keys.
final class SceneObjectId {
  final String source, key;
  SceneObjectId({required this.source, required this.key}) {
    checkText(source, 'source');
    checkText(key, 'key');
  }
  Map<String, Object> toJson() => {'source': source, 'key': key};
  factory SceneObjectId.fromJson(Object? value) {
    final json = objectMap(value);
    return SceneObjectId(
      source: textValue(json['source']),
      key: textValue(json['key']),
    );
  }
  @override
  bool operator ==(Object other) =>
      other is SceneObjectId && source == other.source && key == other.key;
  @override
  int get hashCode => Object.hash(source, key);
  @override
  String toString() => jsonEncode(toJson());
}

/// A complete local transform relative to the object's existing parent.
final class SceneTransform {
  final Vec3 position, scale;
  final Quat rotation;
  SceneTransform({
    this.position = Vec3.zero,
    Quat rotation = Quat.identity,
    this.scale = Vec3.one,
  }) : rotation = rotation.normalized() {
    if (!position.isFinite ||
        !scale.isFinite ||
        scale.x == 0 ||
        scale.y == 0 ||
        scale.z == 0) {
      throw ArgumentError('Transforms must be finite and scale nonzero.');
    }
  }
  factory SceneTransform.capture(Object3D object) => SceneTransform(
    position: object.position,
    rotation: object.quaternion,
    scale: object.scale,
  );
  Map<String, Object> toJson() => {
    'position': position.storage,
    'rotation': [rotation.x, rotation.y, rotation.z, rotation.w],
    'scale': scale.storage,
  };
  factory SceneTransform.fromJson(Object? value) {
    final json = objectMap(value);
    final p = numberArray(json['position'], 3);
    final r = numberArray(json['rotation'], 4);
    final s = numberArray(json['scale'], 3);
    return SceneTransform(
      position: Vec3(p[0], p[1], p[2]),
      rotation: Quat(r[0], r[1], r[2], r[3]),
      scale: Vec3(s[0], s[1], s[2]),
    );
  }
  void apply(Object3D object) {
    object.position = position;
    object.quaternion = rotation;
    object.scale = scale;
  }

  @override
  bool operator ==(Object other) =>
      other is SceneTransform &&
      position == other.position &&
      rotation == other.rotation &&
      scale == other.scale;
  @override
  int get hashCode => Object.hash(position, rotation, scale);
}

enum SceneField { transform, visibility }

final class SceneObjectState {
  final SceneObjectId id;
  final SceneTransform transform;
  final bool visible;
  final int transformRevision, visibilityRevision;
  SceneObjectState({
    required this.id,
    SceneTransform? transform,
    this.visible = true,
    this.transformRevision = 0,
    this.visibilityRevision = 0,
  }) : transform = transform ?? SceneTransform() {
    checkRevision(transformRevision);
    checkRevision(visibilityRevision);
  }
  int revisionFor(SceneField field) => switch (field) {
    SceneField.transform => transformRevision,
    SceneField.visibility => visibilityRevision,
  };
  Map<String, Object> toJson() => {
    'id': id.toJson(),
    'transform': transform.toJson(),
    'visible': visible,
    'transformRevision': transformRevision,
    'visibilityRevision': visibilityRevision,
  };
  factory SceneObjectState.fromJson(Object? value) {
    final json = objectMap(value);
    if (json['visible'] is! bool) {
      throw const FormatException('Expected visible boolean.');
    }
    return SceneObjectState(
      id: SceneObjectId.fromJson(json['id']),
      transform: SceneTransform.fromJson(json['transform']),
      visible: json['visible'] as bool,
      transformRevision: revisionValue(json['transformRevision']),
      visibilityRevision: revisionValue(json['visibilityRevision']),
    );
  }
}

/// Immutable acknowledged state. Epoch changes when history or assets reset.
final class SceneSnapshot {
  static const schemaVersion = 1;
  static const maxCharacters = 4 * 1024 * 1024;
  static const maxObjects = 10000;
  final String sceneId, epoch;
  final int revision;
  final Map<SceneObjectId, SceneObjectState> objects;

  factory SceneSnapshot({
    required String sceneId,
    required String epoch,
    int revision = 0,
    required Iterable<SceneObjectState> objects,
  }) {
    checkText(sceneId, 'sceneId');
    checkText(epoch, 'epoch');
    checkRevision(revision);
    final indexed = <SceneObjectId, SceneObjectState>{};
    for (final object in objects) {
      if (indexed.length >= maxObjects || indexed.containsKey(object.id)) {
        throw ArgumentError('Too many objects or duplicate source identity.');
      }
      if (object.transformRevision > revision ||
          object.visibilityRevision > revision) {
        throw ArgumentError('Field revision exceeds the scene revision.');
      }
      indexed[object.id] = object;
    }
    return SceneSnapshot._(sceneId, epoch, revision, Map.unmodifiable(indexed));
  }
  SceneSnapshot._(this.sceneId, this.epoch, this.revision, this.objects);

  String encode() {
    final ordered = objects.values.toList()
      ..sort((a, b) {
        final source = a.id.source.compareTo(b.id.source);
        return source == 0 ? a.id.key.compareTo(b.id.key) : source;
      });
    return boundedEncode({
      'schemaVersion': schemaVersion,
      'sceneId': sceneId,
      'epoch': epoch,
      'revision': revision,
      'objects': ordered.map((object) => object.toJson()).toList(),
    }, maxCharacters);
  }

  factory SceneSnapshot.decode(String source) => decodeChecked(() {
    final json = boundedDecode(source, maxCharacters);
    if (json['schemaVersion'] != schemaVersion || json['objects'] is! List) {
      throw const FormatException('Unsupported scene snapshot schema.');
    }
    return SceneSnapshot(
      sceneId: textValue(json['sceneId']),
      epoch: textValue(json['epoch']),
      revision: revisionValue(json['revision']),
      objects: (json['objects'] as List).map(SceneObjectState.fromJson),
    );
  });
}

// Codec helpers stay internal to this package's src imports.
void checkText(String value, String field) {
  if (value.trim().isEmpty || value.length > 256) {
    throw ArgumentError('$field must contain 1 to 256 characters.');
  }
}

void checkRevision(int value) {
  if (value < 0 || value > maxSceneRevision) {
    throw ArgumentError('Revision is outside the supported range.');
  }
}

String textValue(Object? value) {
  if (value is! String) throw const FormatException('Expected a string.');
  return value;
}

int revisionValue(Object? value) {
  if (value is! int) throw const FormatException('Expected integer revision.');
  checkRevision(value);
  return value;
}

Map<String, dynamic> objectMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object.');
  }
  return value;
}

List<double> numberArray(Object? value, int size) {
  if (value is! List ||
      value.length != size ||
      value.any((n) => n is! num || !n.isFinite)) {
    throw const FormatException('Expected finite vector components.');
  }
  return value.map((n) => (n as num).toDouble()).toList();
}

String boundedEncode(Object value, int limit) {
  final result = jsonEncode(value);
  if (result.length > limit) throw StateError('Scene payload exceeds limit.');
  return result;
}

Map<String, dynamic> boundedDecode(String source, int limit) {
  if (source.length > limit) {
    throw const FormatException('Scene payload exceeds limit.');
  }
  return objectMap(jsonDecode(source));
}

T decodeChecked<T>(T Function() decode) {
  try {
    return decode();
  } on ArgumentError catch (error) {
    throw FormatException('Invalid scene data: ${error.message}');
  }
}
