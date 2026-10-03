import 'zyren_configurator.dart';

/// Converts glTF variant metadata into a catalog slot. You bind decoded materials
/// and every instance of each source mesh primitive through durable host IDs.
final class ImportedMaterialVariants {
  final ConfigurationSlot slot;
  final Map<String, String> labels;
  ImportedMaterialVariants._(this.slot, this.labels);

  factory ImportedMaterialVariants.fromGltf({
    required Map<String, Object?> document,
    required Map<(int mesh, int primitive), List<String>> targets,
    required Map<int, String> materialIds,
    String slotId = 'material-variant',
    int maxVariants = 256,
    int maxMappings = 16384,
  }) {
    const extension = 'KHR_materials_variants';
    Map object(Object? value) {
      if (value is! Map) throw const FormatException('Expected glTF object.');
      return value;
    }

    List array(Object? value) {
      if (value is! List) throw const FormatException('Expected glTF array.');
      return value;
    }

    int index(Object? value, int length) {
      if (value is! int || value < 0 || value >= length) {
        throw const FormatException('Invalid glTF variant/material index.');
      }
      return value;
    }

    if (maxVariants < 1 || maxMappings < 1) {
      throw ArgumentError('Import budgets must be positive.');
    }
    final root = object(object(document['extensions'])[extension]);
    final variants = array(root['variants']);
    if (variants.isEmpty || variants.length > maxVariants) {
      throw const FormatException('Variant count exceeds import budget.');
    }
    final labels = <String, String>{};
    final writes = List.generate(variants.length, (_) => <String, String>{});
    for (var i = 0; i < variants.length; i++) {
      final name = object(variants[i])['name'];
      if (name is! String || name.trim().isEmpty) {
        throw const FormatException('Variant name must be nonblank.');
      }
      labels['variant:$i'] = name;
    }
    final materials = array(document['materials']);
    final meshes = array(document['meshes']);
    final usedTargets = <String>{};
    var count = 0;
    for (var m = 0; m < meshes.length; m++) {
      final primitives = array(object(meshes[m])['primitives']);
      for (var p = 0; p < primitives.length; p++) {
        final extensions = object(primitives[p])['extensions'];
        if (extensions == null || !object(extensions).containsKey(extension)) {
          continue;
        }
        final bound = targets[(m, p)];
        if (bound == null ||
            bound.isEmpty ||
            bound.any((id) => id.trim().isEmpty || !usedTargets.add(id))) {
          throw const FormatException(
            'Missing or duplicate primitive target IDs.',
          );
        }
        final seen = <int>{};
        final mappings = array(
          object(object(extensions)[extension])['mappings'],
        );
        if (mappings.isEmpty) {
          throw const FormatException('Empty variant mappings.');
        }
        for (final raw in mappings) {
          final mapping = object(raw);
          final material =
              materialIds[index(mapping['material'], materials.length)];
          if (material == null || material.trim().isEmpty) {
            throw const FormatException('Missing decoded material binding.');
          }
          final indices = array(mapping['variants']);
          if (indices.isEmpty) {
            throw const FormatException('Empty mapping variants.');
          }
          for (final rawIndex in indices) {
            final v = index(rawIndex, variants.length);
            if (!seen.add(v)) {
              throw const FormatException('Ambiguous primitive variant.');
            }
            for (final target in bound) {
              if (++count > maxMappings) {
                throw const FormatException('Variant mapping budget exceeded.');
              }
              writes[v][target] = material;
            }
          }
        }
      }
    }
    return ImportedMaterialVariants._(
      ConfigurationSlot(
        id: slotId,
        required: false,
        options: [
          for (var i = 0; i < variants.length; i++)
            ConfigurationOption(id: 'variant:$i', materials: writes[i]),
        ],
      ),
      Map.unmodifiable(labels),
    );
  }
}
