import 'dart:convert';
import 'package:zyren/zyren.dart';

void _id(String value) {
  if (value.trim().isEmpty) throw ArgumentError('IDs must not be blank.');
}

/// One choice within a slot. Target and material IDs belong to your source data.
final class ConfigurationOption {
  final String id;
  final Map<String, String> materials, requires, excludes;
  final Map<String, bool> visibility;
  ConfigurationOption({
    required this.id,
    Map<String, String> materials = const {},
    Map<String, bool> visibility = const {},
    Map<String, String> requires = const {},
    Map<String, String> excludes = const {},
  }) : materials = Map.unmodifiable(materials),
       visibility = Map.unmodifiable(visibility),
       requires = Map.unmodifiable(requires),
       excludes = Map.unmodifiable(excludes) {
    _id(id);
    for (final map in [materials, requires, excludes]) {
      for (final entry in map.entries) {
        _id(entry.key);
        _id(entry.value);
      }
    }
    visibility.keys.forEach(_id);
  }
}

final class ConfigurationSlot {
  final String id;
  final bool required;
  final Map<String, ConfigurationOption> options;
  ConfigurationSlot({
    required this.id,
    required Iterable<ConfigurationOption> options,
    this.required = true,
  }) : options = _index(options, (option) => option.id) {
    _id(id);
    if (this.options.isEmpty) throw ArgumentError('A slot needs options.');
  }
}

Map<String, T> _index<T>(Iterable<T> items, String Function(T) key) {
  final result = <String, T>{};
  for (final item in items) {
    final id = key(item);
    if (result.containsKey(id)) throw ArgumentError('Duplicate ID: $id');
    result[id] = item;
  }
  return Map.unmodifiable(result);
}

final class ConfigurationCatalog {
  final String id;
  final int revision;
  final Map<String, ConfigurationSlot> slots;
  ConfigurationCatalog({
    required this.id,
    required this.revision,
    required Iterable<ConfigurationSlot> slots,
  }) : slots = _index(slots, (slot) => slot.id) {
    _id(id);
    if (revision < 1) throw ArgumentError('Catalog revision must be positive.');
    for (final slot in this.slots.values) {
      for (final option in slot.options.values) {
        for (final rule in [
          ...option.requires.entries,
          ...option.excludes.entries,
        ]) {
          if (this.slots[rule.key]?.options.containsKey(rule.value) != true) {
            throw ArgumentError(
              'Unknown rule reference: ${rule.key}/${rule.value}',
            );
          }
        }
      }
    }
  }

  SavedConfiguration select(Map<String, String> choices) {
    final saved = SavedConfiguration(id, revision, choices);
    validate(saved);
    return saved;
  }

  void validate(SavedConfiguration saved) {
    if (saved.catalogId != id || saved.catalogRevision != revision) {
      throw ArgumentError(
        'Configuration belongs to a different catalog revision.',
      );
    }
    for (final entry in saved.choices.entries) {
      if (slots[entry.key]?.options.containsKey(entry.value) != true) {
        throw ArgumentError('Unknown choice: ${entry.key}/${entry.value}');
      }
    }
    final materialWrites = <String>{}, visibilityWrites = <String>{};
    for (final slot in slots.values) {
      final choice = saved.choices[slot.id];
      if (choice == null) {
        if (slot.required) throw ArgumentError('Missing choice: ${slot.id}');
        continue;
      }
      final option = slot.options[choice]!;
      for (final rule in option.requires.entries) {
        if (saved.choices[rule.key] != rule.value) {
          throw ArgumentError(
            '${slot.id}/$choice requires ${rule.key}/${rule.value}',
          );
        }
      }
      for (final rule in option.excludes.entries) {
        if (saved.choices[rule.key] == rule.value) {
          throw ArgumentError(
            '${slot.id}/$choice excludes ${rule.key}/${rule.value}',
          );
        }
      }
      for (final target in option.materials.keys) {
        if (!materialWrites.add(target)) {
          throw ArgumentError('Conflicting material writes: $target');
        }
      }
      for (final target in option.visibility.keys) {
        if (!visibilityWrites.add(target)) {
          throw ArgumentError('Conflicting visibility writes: $target');
        }
      }
    }
  }
}

/// Versioned selections only. Scene objects and material instances are rebound.
final class SavedConfiguration {
  static const schemaVersion = 1;
  final String catalogId;
  final int catalogRevision;
  final Map<String, String> choices;
  SavedConfiguration(
    this.catalogId,
    this.catalogRevision,
    Map<String, String> choices,
  ) : choices = Map.unmodifiable(choices) {
    _id(catalogId);
    if (catalogRevision < 1) throw ArgumentError('Invalid catalog revision.');
    for (final entry in choices.entries) {
      _id(entry.key);
      _id(entry.value);
    }
  }

  String encode() {
    final keys = choices.keys.toList()..sort();
    return jsonEncode({
      'schemaVersion': schemaVersion,
      'catalogId': catalogId,
      'catalogRevision': catalogRevision,
      'choices': {for (final key in keys) key: choices[key]},
    });
  }

  factory SavedConfiguration.decode(String source) {
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] != schemaVersion ||
        value['catalogId'] is! String ||
        value['catalogRevision'] is! int ||
        value['choices'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid configuration document.');
    }
    final choices = value['choices'] as Map<String, dynamic>;
    if (choices.values.any((value) => value is! String)) {
      throw const FormatException('Choice IDs must be strings.');
    }
    try {
      return SavedConfiguration(
        value['catalogId'] as String,
        value['catalogRevision'] as int,
        choices.cast<String, String>(),
      );
    } on ArgumentError {
      throw const FormatException('Invalid configuration identities.');
    }
  }
}

/// Owns configuration writes, but never disposes your nodes or materials.
/// Reserve the catalog's material/visibility properties for this controller.
final class SceneConfigurator {
  final ConfigurationCatalog catalog;
  final Map<String, Object3D> _targets;
  final Map<String, MeshMaterial> _materials;
  final _baseMaterials = <Mesh, MeshMaterial>{};
  final _baseVisibility = <Object3D, bool>{};
  SavedConfiguration? _current;
  bool _closed = false;

  SceneConfigurator({
    required this.catalog,
    required Map<String, Object3D> targets,
    required Map<String, MeshMaterial> materials,
  }) : _targets = Map.unmodifiable(targets),
       _materials = Map.unmodifiable(materials) {
    if (targets.values.toSet().length != targets.length) {
      throw ArgumentError(
        'Each target object must have exactly one stable ID.',
      );
    }
    for (final slot in catalog.slots.values) {
      for (final option in slot.options.values) {
        for (final entry in option.materials.entries) {
          final mesh = _mesh(entry.key, entry.value);
          _baseMaterials[mesh] = mesh.material;
        }
        for (final id in option.visibility.keys) {
          final node = _targets[id];
          if (node == null) throw ArgumentError('Missing target: $id');
          _baseVisibility[node] = node.visible;
        }
      }
    }
  }

  SavedConfiguration? get current => _current;

  Mesh _mesh(String targetId, String materialId) {
    final target = _targets[targetId], material = _materials[materialId];
    if (target is! Mesh || material == null) {
      throw ArgumentError(
        'Missing mesh/material binding: $targetId/$materialId',
      );
    }
    final kind = switch (target.geometry.topology) {
      GeometryTopology.triangles => 0,
      GeometryTopology.lineSegments || GeometryTopology.lineStrip => 1,
      GeometryTopology.points => 2,
    };
    if (material.primitiveKind != kind) {
      throw ArgumentError(
        'Material topology differs for $targetId/$materialId',
      );
    }
    return target;
  }

  void apply(SavedConfiguration saved) {
    _checkOpen();
    catalog.validate(saved);
    final materialWrites = <Mesh, MeshMaterial>{};
    final visibilityWrites = <Object3D, bool>{};
    for (final entry in saved.choices.entries) {
      final option = catalog.slots[entry.key]!.options[entry.value]!;
      for (final binding in option.materials.entries) {
        materialWrites[_mesh(binding.key, binding.value)] =
            _materials[binding.value]!;
      }
      for (final binding in option.visibility.entries) {
        visibilityWrites[_targets[binding.key]!] = binding.value;
      }
    }
    // All potentially failing validation precedes synchronous scene writes.
    for (final entry in _baseMaterials.entries) {
      entry.key.material = materialWrites[entry.key] ?? entry.value;
    }
    for (final entry in _baseVisibility.entries) {
      entry.key.visible = visibilityWrites[entry.key] ?? entry.value;
    }
    _current = saved;
  }

  void restore(String source) => apply(SavedConfiguration.decode(source));

  void reset() {
    _checkOpen();
    for (final entry in _baseMaterials.entries) {
      entry.key.material = entry.value;
    }
    for (final entry in _baseVisibility.entries) {
      entry.key.visible = entry.value;
    }
    _current = null;
  }

  void close() {
    if (_closed) return;
    reset();
    _closed = true;
  }

  void _checkOpen() {
    if (_closed) throw StateError('Configurator has closed.');
  }
}
