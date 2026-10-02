part of '../zyren_agents.dart';

/// Deliberately small JSON Schema subset. Unsupported keywords fail at
/// registration, so a advertised constraint cannot silently go unenforced.
abstract final class AgentSchema {
  static const _keys = {
    'type',
    'description',
    'title',
    'properties',
    'required',
    'additionalProperties',
    'items',
    'minItems',
    'maxItems',
    'minimum',
    'maximum',
    'minLength',
    'maxLength',
    'enum',
  };
  static void check(Map<String, Object?> schema) {
    if (schema.keys.any((key) => !_keys.contains(key))) {
      throw ArgumentError('Unsupported schema keyword. Supported: $_keys');
    }
    if (!{
      'object',
      'array',
      'string',
      'number',
      'integer',
      'boolean',
      'null',
    }.contains(schema['type'])) {
      throw ArgumentError('Schema requires a supported type.');
    }
    for (final key in [
      'minimum',
      'maximum',
      'minLength',
      'maxLength',
      'minItems',
      'maxItems',
    ]) {
      final value = schema[key];
      if (value != null && (value is! num || !value.isFinite)) {
        throw ArgumentError('Schema $key must be finite.');
      }
    }
    final properties = schema['properties'];
    if (properties != null) {
      if (properties is! Map) {
        throw ArgumentError('properties must be an object.');
      }
      for (final value in properties.values) {
        if (value is! Map) {
          throw ArgumentError('Property schema must be an object.');
        }
        check(Map<String, Object?>.from(value));
      }
    }
    final required = schema['required'];
    if (required != null &&
        (required is! List ||
            required.any(
              (key) =>
                  key is! String ||
                  properties is! Map ||
                  !properties.containsKey(key),
            ))) {
      throw ArgumentError('Required fields must name declared properties.');
    }
    if (schema.containsKey('additionalProperties') &&
        schema['additionalProperties'] is! bool) {
      throw ArgumentError('additionalProperties must be boolean.');
    }
    if (schema['type'] == 'array') {
      final items = schema['items'];
      if (items is! Map) throw ArgumentError('Arrays require an items schema.');
      check(Map<String, Object?>.from(items));
    }
    if (schema.containsKey('enum') &&
        (schema['enum'] is! List || (schema['enum'] as List).isEmpty)) {
      throw ArgumentError('enum must contain values.');
    }
  }

  static String? validate(
    Map<String, Object?> schema,
    Object? value, [
    String path = r'$',
  ]) {
    final valid = switch (schema['type']) {
      'object' => value is Map<String, Object?>,
      'array' => value is List,
      'string' => value is String,
      'number' => value is num && value.isFinite,
      'integer' => value is int,
      'boolean' => value is bool,
      'null' => value == null,
      _ => false,
    };
    if (!valid) return '$path must have type ${schema['type']}.';
    if (schema['enum'] case final List choices) {
      if (!choices.any((choice) => jsonEncode(choice) == jsonEncode(value))) {
        return '$path is outside enum.';
      }
    }
    if (value is num) {
      if (schema['minimum'] case final num min) {
        if (value < min) return '$path is below minimum.';
      }
      if (schema['maximum'] case final num max) {
        if (value > max) return '$path is above maximum.';
      }
    }
    if (value is String) {
      if (schema['minLength'] case final num min) {
        if (value.length < min) return '$path is too short.';
      }
      if (schema['maxLength'] case final num max) {
        if (value.length > max) return '$path is too long.';
      }
    }
    if (value is List) {
      if (schema['minItems'] case final num min) {
        if (value.length < min) return '$path has too few items.';
      }
      if (schema['maxItems'] case final num max) {
        if (value.length > max) return '$path has too many items.';
      }
      for (var i = 0; i < value.length; i++) {
        final error = validate(
          Map<String, Object?>.from(schema['items'] as Map),
          value[i],
          '$path[$i]',
        );
        if (error != null) return error;
      }
    }
    if (value is Map<String, Object?>) {
      final properties = (schema['properties'] as Map?) ?? const {};
      for (final required in (schema['required'] as List?) ?? const []) {
        if (!value.containsKey(required)) return '$path.$required is required.';
      }
      for (final entry in value.entries) {
        if (!properties.containsKey(entry.key)) {
          if (schema['additionalProperties'] == false) {
            return '$path.${entry.key} is unknown.';
          }
        } else {
          final error = validate(
            Map<String, Object?>.from(properties[entry.key] as Map),
            entry.value,
            '$path.${entry.key}',
          );
          if (error != null) return error;
        }
      }
    }
    return null;
  }
}
