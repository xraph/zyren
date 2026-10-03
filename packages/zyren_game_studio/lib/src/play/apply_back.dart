part of '../../apply_back.dart';

final class GameRuntimeEntitySnapshot {
  final String nodeId;
  final Vec3 position, scale;
  final Quat rotation;
  final Map<String, Map<String, Object?>> components;
  GameRuntimeEntitySnapshot({
    required this.nodeId,
    required this.position,
    required this.rotation,
    required this.scale,
    Map<String, Map<String, Object?>> components = const {},
  }) : components = Map.unmodifiable(
         components.map(
           (k, v) => MapEntry(k, GameComponentRecord(k, 1, v).data),
         ),
       ) {
    if (nodeId.isEmpty ||
        nodeId.length > 1024 ||
        components.length > 64 ||
        !position.isFinite ||
        !rotation.isFinite ||
        !scale.isFinite) {
      throw ArgumentError('Invalid runtime transform.');
    }
  }
}

final class GameRuntimeSnapshot {
  final String buildId;
  final int tick;
  final List<GameRuntimeEntitySnapshot> entities;
  GameRuntimeSnapshot({
    required this.buildId,
    required this.tick,
    required List<GameRuntimeEntitySnapshot> entities,
  }) : entities = List.unmodifiable(entities) {
    if (buildId.isEmpty ||
        tick < 0 ||
        entities.length > 10000 ||
        entities.map((e) => e.nodeId).toSet().length != entities.length) {
      throw ArgumentError('Invalid runtime snapshot.');
    }
  }
}

final class StaleApplyBack implements Exception {
  const StaleApplyBack();
  @override
  String toString() =>
      'The authoring revision changed. Prepare a new apply-back diff.';
}

final class GameApplyBackField {
  final String id, nodeId, path;
  final Object? before, after;
  GameApplyBackField._(this.nodeId, this.path, Object? before, Object? after)
    : id = jsonEncode([nodeId, path]),
      before = _immutable(before),
      after = _immutable(after);
}

Object? _immutable(Object? v) => v is Map
    ? Map<String, Object?>.unmodifiable(
        v.map((k, v) => MapEntry(k as String, _immutable(v))),
      )
    : v is List
    ? List<Object?>.unmodifiable(v.map(_immutable))
    : v;

final class GameApplyBackDiff {
  final GameApplyBack _owner;
  final int authoredRevision;
  final String authoredDocument, buildId;
  final List<GameApplyBackField> fields;
  GameApplyBackDiff._(
    this._owner,
    this.authoredRevision,
    this.authoredDocument,
    this.buildId,
    List<GameApplyBackField> fields,
  ) : fields = List.unmodifiable(fields);
}

/// Only caller-approved definition fields and transforms enter the authored scene.
final class GameApplyBack {
  final StudioScene scene;
  final GameAuthoring authoring;
  final Map<String, Set<String>> editableFields;
  GameApplyBack({
    required this.scene,
    required this.authoring,
    Map<String, Set<String>> editableFields = const {},
  }) : editableFields = Map.unmodifiable(
         editableFields.map((k, v) => MapEntry(k, Set<String>.unmodifiable(v))),
       ) {
    for (final entry in this.editableFields.entries) {
      final descriptor = authoring.descriptors[entry.key];
      if (descriptor == null ||
          entry.value.any(
            (f) => !descriptor.fields.any((d) => d.name == f) || _forbidden(f),
          )) {
        throw ArgumentError('Apply-back requires editable definition fields.');
      }
    }
  }
  static bool _forbidden(String field) => RegExp(
    r'(^|[._-])(id|ids|health|neural|hidden|generation|epoch|tick|memory|state)([._-]|$)',
    caseSensitive: false,
  ).hasMatch(field);
  GameApplyBackDiff prepare(int authoredRevision, GameRuntimeSnapshot runtime) {
    if (scene.revision != authoredRevision) throw const StaleApplyBack();
    final doc = scene.capture();
    final fields = <GameApplyBackField>[];
    void add(String node, String path, Object? before, Object? after) {
      if (jsonEncode(before) != jsonEncode(after)) {
        fields.add(GameApplyBackField._(node, path, before, after));
      }
    }

    for (final entity in runtime.entities) {
      final node = doc.expandedNodes[entity.nodeId];
      if (node == null) continue;
      add(
        node.id,
        'transform.position',
        node.position.storage,
        entity.position.storage,
      );
      add(
        node.id,
        'transform.rotation',
        [node.rotation.x, node.rotation.y, node.rotation.z, node.rotation.w],
        [
          entity.rotation.x,
          entity.rotation.y,
          entity.rotation.z,
          entity.rotation.w,
        ],
      );
      add(node.id, 'transform.scale', node.scale.storage, entity.scale.storage);
      final authored = authoring.entityFor(doc, node.id);
      for (final component in authored?.components ?? <GameComponentRecord>[]) {
        for (final field in editableFields[component.type] ?? <String>{}) {
          final values = entity.components[component.type];
          if (values != null && values.containsKey(field)) {
            add(
              node.id,
              '${component.type}.$field',
              component.data[field],
              values[field],
            );
          }
        }
      }
    }
    return GameApplyBackDiff._(
      this,
      authoredRevision,
      doc.encode(),
      runtime.buildId,
      fields,
    );
  }

  void commit(
    GameApplyBackDiff diff, {
    required int expectedRevision,
    required Set<String> selectedFields,
  }) {
    if (!identical(diff._owner, this)) {
      throw ArgumentError('Apply-back diff belongs to another scene.');
    }
    if (scene.revision != expectedRevision ||
        expectedRevision != diff.authoredRevision ||
        scene.capture().encode() != diff.authoredDocument) {
      throw const StaleApplyBack();
    }
    final byId = {for (final field in diff.fields) field.id: field};
    if (!byId.keys.toSet().containsAll(selectedFields)) {
      throw ArgumentError('Unknown apply-back field.');
    }
    if (selectedFields.isEmpty) return;
    var next = scene.document;
    final componentFields = <String, Map<String, Map<String, Object?>>>{};
    for (final id in selectedFields) {
      final field = byId[id]!;
      if (field.path.startsWith('transform.')) {
        final values = (field.after as List).cast<num>();
        next = StudioAuthoring.updateNode(
          next,
          field.nodeId,
          StudioOverride(
            position: field.path == 'transform.position'
                ? Vec3(
                    values[0].toDouble(),
                    values[1].toDouble(),
                    values[2].toDouble(),
                  )
                : null,
            rotation: field.path == 'transform.rotation'
                ? Quat(
                    values[0].toDouble(),
                    values[1].toDouble(),
                    values[2].toDouble(),
                    values[3].toDouble(),
                  )
                : null,
            scale: field.path == 'transform.scale'
                ? Vec3(
                    values[0].toDouble(),
                    values[1].toDouble(),
                    values[2].toDouble(),
                  )
                : null,
          ),
        );
      } else {
        final split = field.path.lastIndexOf('.');
        final component = field.path.substring(0, split),
            name = field.path.substring(split + 1);
        (componentFields
                .putIfAbsent(field.nodeId, () => {})
                .putIfAbsent(component, () => {}))[name] =
            field.after;
      }
    }
    for (final node in componentFields.entries) {
      for (final component in node.value.entries) {
        next = authoring.setFields(
          next,
          nodeId: node.key,
          component: component.key,
          fields: component.value,
        );
      }
    }
    final issues = authoring.validate(next).where((i) => i.blocksEdit).toList();
    if (issues.isNotEmpty) throw GameAuthoringException(issues);
    scene.extensionRegistry.validateDocument(next);
    if (scene.revision != expectedRevision) throw const StaleApplyBack();
    scene.apply(next);
  }
}
