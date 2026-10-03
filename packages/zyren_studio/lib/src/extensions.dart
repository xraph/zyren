part of '../zyren_studio.dart';

/// Namespaced authoring payload. Unknown codecs do not prevent lossless saving.
final class StudioExtensionRecord {
  static const maxBytes = 512 * 1024;
  final String namespace;
  final int schemaVersion;
  final bool required;
  final Map<String, Object?> data;
  late final int byteLength;

  StudioExtensionRecord({
    required this.namespace,
    required this.schemaVersion,
    required this.required,
    required Map<String, Object?> data,
  }) : data = _freezeJson(data) as Map<String, Object?> {
    if (namespace.length > 128 ||
        !RegExp(
          r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_-]*)+$',
        ).hasMatch(namespace) ||
        schemaVersion < 1 ||
        schemaVersion > 65535) {
      throw ArgumentError('Invalid extension namespace or version.');
    }
    byteLength = utf8.encode(jsonEncode(toJson())).length;
    if (byteLength > maxBytes) {
      throw ArgumentError('Extension payload exceeds byte budget.');
    }
  }

  factory StudioExtensionRecord.fromJson(
    String namespace,
    Map<String, dynamic> json,
  ) => StudioExtensionRecord(
    namespace: namespace,
    schemaVersion: json['schemaVersion'] as int,
    required: json['required'] as bool,
    data: json['data'] as Map<String, dynamic>,
  );
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'required': required,
    'data': data,
  };
  StudioExtensionRecord copyWith({
    int? schemaVersion,
    bool? required,
    Map<String, Object?>? data,
  }) => StudioExtensionRecord(
    namespace: namespace,
    schemaVersion: schemaVersion ?? this.schemaVersion,
    required: required ?? this.required,
    data: data ?? this.data,
  );
}

/// A codec defines references and migration without importing its domain into Studio.
abstract interface class StudioExtensionCodec {
  String get namespace;
  int get schemaVersion;
  void validate(StudioExtensionRecord record, StudioDocument document);
  StudioExtensionRecord migrate(StudioExtensionRecord record);
  Iterable<String> referencedNodeIds(StudioExtensionRecord record);
  StudioExtensionRecord remapNodeIds(
    StudioExtensionRecord record,
    Map<String, String> ids,
  );
  StudioExtensionRecord applyOverrides(
    StudioExtensionRecord record,
    Map<String, Object?> overrides,
  );
}

final class StudioExtensionRegistry {
  final _codecs = <String, StudioExtensionCodec>{};
  Registration register(StudioExtensionCodec codec) {
    if (_codecs.containsKey(codec.namespace)) {
      throw ArgumentError('Duplicate extension codec.');
    }
    // Validate the codec identity through the same envelope contract.
    StudioExtensionRecord(
      namespace: codec.namespace,
      schemaVersion: codec.schemaVersion,
      required: false,
      data: const {},
    );
    _codecs[codec.namespace] = codec;
    return Registration(() {
      if (identical(_codecs[codec.namespace], codec)) {
        _codecs.remove(codec.namespace);
      }
    });
  }

  StudioExtensionCodec? _codec(StudioExtensionRecord record) {
    final codec = _codecs[record.namespace];
    return codec?.schemaVersion == record.schemaVersion ? codec : null;
  }

  void validateDocument(
    StudioDocument document, {
    bool requireSupported = false,
  }) {
    for (final record in document.extensions.values) {
      final codec = _codec(record);
      if (codec == null) {
        if (requireSupported && record.required) {
          throw StateError(
            'Required extension ${record.namespace}@${record.schemaVersion} is unavailable.',
          );
        }
        continue;
      }
      codec.validate(record, document);
      for (final id in codec.referencedNodeIds(record)) {
        if (!document.expandedNodes.containsKey(id)) {
          throw ArgumentError(
            'Extension ${record.namespace} references missing node $id.',
          );
        }
      }
    }
  }

  StudioDocument migrateDocument(StudioDocument document) {
    final records = {...document.extensions};
    for (final record in document.extensions.values) {
      final codec = _codecs[record.namespace];
      if (codec == null || record.schemaVersion >= codec.schemaVersion) {
        continue;
      }
      final migrated = codec.migrate(record);
      _checkIdentity(record, migrated, codec.schemaVersion);
      records[record.namespace] = migrated;
    }
    final next = document.copyWith(extensions: records);
    validateDocument(next);
    return next;
  }

  void validateEdit(StudioDocument before, StudioDocument after) {
    final removed = before.expandedNodes.keys.toSet().difference(
      after.expandedNodes.keys.toSet(),
    );
    if (removed.isNotEmpty) {
      for (final record in before.extensions.values) {
        if (_codec(record) == null &&
            after.extensions.containsKey(record.namespace)) {
          throw StateError(
            'Load extension ${record.namespace} before editing referenced structure.',
          );
        }
      }
    }
    validateDocument(after);
  }

  StudioDocument remapDocument(
    StudioDocument before,
    StudioDocument after,
    Map<String, String> ids,
  ) {
    final records = {...after.extensions};
    for (final record in before.extensions.values) {
      final codec = _codec(record);
      if (codec == null && ids.isNotEmpty) {
        throw StateError(
          'Load extension ${record.namespace} before remapping node identities.',
        );
      }
      if (codec != null) {
        final mapped = codec.remapNodeIds(record, Map.unmodifiable(ids));
        _checkIdentity(record, mapped, record.schemaVersion);
        records[record.namespace] = mapped;
      }
    }
    final next = after.copyWith(extensions: records);
    validateEdit(before, next);
    return next;
  }

  StudioDocument applyOverrides(
    StudioDocument document,
    String namespace,
    Map<String, Object?> overrides,
  ) {
    final record = document.extensions[namespace];
    if (record == null) throw ArgumentError('Unknown document extension.');
    final codec = _codec(record);
    if (codec == null) throw StateError('Extension codec is unavailable.');
    final next = codec.applyOverrides(
      record,
      _freezeJson(overrides) as Map<String, Object?>,
    );
    _checkIdentity(record, next, record.schemaVersion);
    return StudioAuthoring.updateExtension(document, next, registry: this);
  }

  void _checkIdentity(
    StudioExtensionRecord before,
    StudioExtensionRecord after,
    int version,
  ) {
    if (before.namespace != after.namespace ||
        after.schemaVersion != version ||
        before.required != after.required) {
      throw StateError('Extension codec changed its envelope identity.');
    }
  }
}
