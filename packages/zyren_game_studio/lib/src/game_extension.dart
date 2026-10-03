part of '../authoring.dart';

enum GameFieldKind {
  number,
  integer,
  text,
  boolean,
  choice,
  entity,
  vector,
  json,
}

enum GameFieldOrigin { authored, inherited, overridden, missing }

final class GameFieldDescriptor {
  final String name, label, unit;
  final GameFieldKind kind;
  final Object? defaultValue;
  final bool required;
  final num? minimum, maximum;
  final List<String> choices;
  final Map<String, Object?>? entryTemplate;
  final int entryBatchSize;
  const GameFieldDescriptor(
    this.name,
    this.label,
    this.kind, {
    this.defaultValue,
    this.required = true,
    this.unit = '',
    this.minimum,
    this.maximum,
    this.choices = const [],
    this.entryTemplate,
    this.entryBatchSize = 1,
  });
  String? validate(Object? value) {
    if (value == null) return required ? '$label is required.' : null;
    final valid = switch (kind) {
      GameFieldKind.number => value is num && value.isFinite,
      GameFieldKind.integer => value is int,
      GameFieldKind.text || GameFieldKind.entity =>
        value is String && value.isNotEmpty && value.length <= 1024,
      GameFieldKind.boolean => value is bool,
      GameFieldKind.choice => value is String && choices.contains(value),
      GameFieldKind.vector =>
        value is List &&
            value.length == 3 &&
            value.every((v) => v is num && v.isFinite),
      GameFieldKind.json => value is Map || value is List,
    };
    if (!valid) return '$label has an invalid value.';
    if (value is num &&
        (minimum != null && value < minimum! ||
            maximum != null && value > maximum!)) {
      return '$label must be between ${minimum ?? "unbounded"} and ${maximum ?? "unbounded"}${unit.isEmpty ? "" : " $unit"}.';
    }
    return null;
  }
}

final class GameComponentDescriptor {
  final String type, label;
  final int version;
  final List<GameFieldDescriptor> fields;
  final Set<String> dependencies;
  final Map<String, Object?> defaults;
  GameComponentDescriptor({
    required this.type,
    required this.label,
    this.version = 1,
    required List<GameFieldDescriptor> fields,
    Set<String> dependencies = const {},
    Map<String, Object?> defaults = const {},
  }) : fields = List.unmodifiable(fields),
       dependencies = Set.unmodifiable(dependencies),
       defaults = GameComponentRecord(type, version, defaults).data;
  GameComponentRecord create() => GameComponentRecord(type, version, {
    for (final field in fields)
      if (field.defaultValue != null) field.name: field.defaultValue,
    ...defaults,
  });
}

enum GameRepairKind { removeComponent, addDependency, selectTarget }

final class GameRepairCommand {
  final GameRepairKind kind;
  final String nodeId, component;
  final String? field;
  const GameRepairCommand(this.kind, this.nodeId, this.component, {this.field});
}

final class GameAuthoringIssue {
  final String message;
  final String? nodeId, component, field;
  final bool blocksEdit, blocksPlay;
  final GameRepairCommand? repair;
  const GameAuthoringIssue(
    this.message, {
    this.nodeId,
    this.component,
    this.field,
    this.blocksEdit = true,
    this.blocksPlay = true,
    this.repair,
  });
}

final class GameAuthoringException implements Exception {
  final List<GameAuthoringIssue> issues;
  GameAuthoringException(Iterable<GameAuthoringIssue> issues)
    : issues = List.unmodifiable(issues);
  @override
  String toString() => issues.map((i) => i.message).join('\n');
}
