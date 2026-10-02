part of '../zyren_engineering.dart';

/// One source-owned identity paired with its imported scene object.
final class EngineeringImportEntry {
  final EngineeringObject record;
  final Object3D object;
  const EngineeringImportEntry({required this.record, required this.object});
}

/// A complete binding snapshot produced by the host's model importer.
/// The host must obtain keys from source metadata or an export sidecar.
final class EngineeringImport {
  final List<EngineeringImportEntry> entries;
  EngineeringImport(Iterable<EngineeringImportEntry> entries)
    : entries = List.unmodifiable(entries) {
    final ids = <String>{};
    for (final entry in this.entries) {
      if (!ids.add(entry.record.id)) {
        throw ArgumentError('Duplicate imported source ID ${entry.record.id}.');
      }
    }
    if (this.entries.length > 10000) {
      throw ArgumentError('Import exceeds the record limit.');
    }
  }

  /// Resolve a version-pinned export sidecar against a loaded model hierarchy.
  /// Child paths locate runtime nodes; source IDs remain the persistent keys.
  factory EngineeringImport.fromSidecar({
    required Object3D root,
    required String modelVersion,
    required String source,
  }) {
    _text(modelVersion, 'Model version', 256);
    if (source.length > EngineeringDocument.maxCharacters) {
      throw const FormatException('Import sidecar exceeds the size limit.');
    }
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic> ||
        data['schemaVersion'] != 1 ||
        data['modelVersion'] != modelVersion ||
        data['entries'] is! List ||
        (data['entries'] as List).length > 10000) {
      throw const FormatException(
        'Invalid sidecar or mismatched model version.',
      );
    }
    final entries = <EngineeringImportEntry>[];
    try {
      for (final entry in data['entries'] as List) {
        if (entry is! Map<String, dynamic> ||
            entry['id'] is! String ||
            entry['label'] is! String ||
            entry['properties'] is! Map<String, dynamic> ||
            entry['path'] is! List ||
            (entry['path'] as List).length > 256) {
          throw const FormatException('Invalid import entry.');
        }
        Object3D object = root;
        for (final index in entry['path'] as List) {
          if (index is! int || index < 0 || index >= object.children.length) {
            throw const FormatException('Import path does not resolve.');
          }
          object = object.children[index];
        }
        entries.add(
          EngineeringImportEntry(
            record: EngineeringObject(
              id: entry['id'] as String,
              label: entry['label'] as String,
              properties: entry['properties'] as Map<String, dynamic>,
            ),
            object: object,
          ),
        );
      }
      final imported = EngineeringImport(entries);
      if (entries.map((entry) => entry.object).toSet().length !=
          entries.length) {
        throw const FormatException(
          'More than one source ID resolves to a node.',
        );
      }
      return imported;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid import sidecar: ${error.message}');
    }
  }
}
