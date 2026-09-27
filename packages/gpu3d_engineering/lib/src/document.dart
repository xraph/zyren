part of '../gpu3d_engineering.dart';

final class EngineeringObject {
  final String id, label;
  final Map<String, Object?> properties;
  EngineeringObject({
    required this.id,
    required this.label,
    Map<String, Object?> properties = const {},
  }) : properties = Map.unmodifiable(properties) {
    _text(id, 'Object ID', 256);
    _text(label, 'Label', 240);
    if (properties.length > 64) {
      throw ArgumentError('A record supports at most 64 properties.');
    }
    for (final entry in properties.entries) {
      _text(entry.key, 'Property name', 128);
      final value = entry.value;
      if (!(value == null ||
              value is bool ||
              value is String ||
              value is num) ||
          value is num && !value.isFinite ||
          value is String && value.length > 4096) {
        throw ArgumentError(
          'Metadata values must be finite JSON scalars of at most 4096 characters.',
        );
      }
    }
  }
  Map<String, Object?> _json() => {
    'id': id,
    'label': label,
    'properties': properties,
  };
}

final class EngineeringAnnotation {
  final String id, objectId, text;
  final Vec3 anchor;
  EngineeringAnnotation({
    required this.id,
    required this.objectId,
    required this.text,
    required this.anchor,
  }) {
    _text(id, 'Annotation ID', 256);
    _text(objectId, 'Object ID', 256);
    _text(text, 'Annotation text', 4096);
    if (!anchor.isFinite) {
      throw ArgumentError('Annotation anchor must be finite.');
    }
  }
  Map<String, Object> _json() => {
    'id': id,
    'objectId': objectId,
    'text': text,
    'anchor': anchor.storage,
  };
}

/// Immutable review data. IDs belong to the source model, not a runtime scene.
final class EngineeringDocument {
  static const schemaVersion = 1;
  static const maxCharacters = 2 * 1024 * 1024;
  final String id;
  final Map<String, EngineeringObject> objects;
  final Map<String, EngineeringAnnotation> annotations;
  factory EngineeringDocument({
    required String id,
    Iterable<EngineeringObject> objects = const [],
    Iterable<EngineeringAnnotation> annotations = const [],
  }) {
    _text(id, 'Document ID', 256);
    final records = <String, EngineeringObject>{};
    final notes = <String, EngineeringAnnotation>{};
    for (final record in objects) {
      if (records.containsKey(record.id)) {
        throw ArgumentError('Duplicate object ID ${record.id}.');
      }
      records[record.id] = record;
    }
    for (final note in annotations) {
      if (notes.containsKey(note.id)) {
        throw ArgumentError('Duplicate annotation ID ${note.id}.');
      }
      if (!records.containsKey(note.objectId)) {
        throw ArgumentError('Annotation references an unknown object.');
      }
      notes[note.id] = note;
    }
    if (records.length > 10000 || notes.length > 10000) {
      throw ArgumentError('Review exceeds the record limit.');
    }
    return EngineeringDocument._(
      id,
      Map.unmodifiable(records),
      Map.unmodifiable(notes),
    );
  }
  EngineeringDocument._(this.id, this.objects, this.annotations);

  String encode() {
    final result = jsonEncode({
      'schemaVersion': schemaVersion,
      'documentId': id,
      'objects': objects.values.map((record) => record._json()).toList(),
      'annotations': annotations.values.map((note) => note._json()).toList(),
    });
    if (result.length > maxCharacters) {
      throw StateError('Review exceeds the document size limit.');
    }
    return result;
  }

  factory EngineeringDocument.decode(String source) {
    if (source.length > maxCharacters) {
      throw const FormatException('Review exceeds the document size limit.');
    }
    try {
      final root = jsonDecode(source);
      if (root is! Map<String, dynamic> ||
          root['schemaVersion'] != schemaVersion ||
          root['documentId'] is! String ||
          root['objects'] is! List ||
          root['annotations'] is! List) {
        throw const FormatException('Unsupported review document schema.');
      }
      final records = <EngineeringObject>[];
      for (final value in root['objects'] as List) {
        if (value is! Map<String, dynamic> ||
            value['id'] is! String ||
            value['label'] is! String ||
            value['properties'] is! Map<String, dynamic>) {
          throw const FormatException('Invalid object record.');
        }
        records.add(
          EngineeringObject(
            id: value['id'] as String,
            label: value['label'] as String,
            properties: value['properties'] as Map<String, dynamic>,
          ),
        );
      }
      final notes = <EngineeringAnnotation>[];
      for (final value in root['annotations'] as List) {
        if (value is! Map<String, dynamic> ||
            value['id'] is! String ||
            value['objectId'] is! String ||
            value['text'] is! String ||
            value['anchor'] is! List) {
          throw const FormatException('Invalid annotation record.');
        }
        final anchor = value['anchor'] as List;
        if (anchor.length != 3 ||
            anchor.any((value) => value is! num || !value.isFinite)) {
          throw const FormatException('Invalid annotation anchor.');
        }
        notes.add(
          EngineeringAnnotation(
            id: value['id'] as String,
            objectId: value['objectId'] as String,
            text: value['text'] as String,
            anchor: Vec3.array(
              anchor.map((value) => (value as num).toDouble()).toList(),
            ),
          ),
        );
      }
      return EngineeringDocument(
        id: root['documentId'] as String,
        objects: records,
        annotations: notes,
      );
    } on ArgumentError catch (error) {
      throw FormatException('Invalid review: ${error.message}');
    }
  }
}

void _text(String value, String field, int limit) {
  if (value.trim().isEmpty || value.length > limit) {
    throw ArgumentError('$field must contain 1 to $limit characters.');
  }
}
