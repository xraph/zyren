import 'package:zyren/zyren.dart';
import '../tiling.dart';
import 'controller.dart';
import 'document.dart';
import 'layer.dart';

/// A migration at key N converts schema N to N + 1.
final class GeoLayerConfigurationCodec<T extends Object> {
  final String kind;
  final int schemaVersion;
  final Map<String, Object?> Function(T value) encode;
  final T Function(Map<String, Object?> document) decode;
  final Map<int, Map<String, Object?> Function(Map<String, Object?>)>
  migrations;
  GeoLayerConfigurationCodec({
    required this.kind,
    required this.schemaVersion,
    required this.encode,
    required this.decode,
    Map<int, Map<String, Object?> Function(Map<String, Object?>)> migrations =
        const {},
  }) : migrations = Map.unmodifiable(migrations) {
    if (kind.trim().isEmpty ||
        schemaVersion < 1 ||
        migrations.keys.any((v) => v < 1 || v >= schemaVersion)) {
      throw ArgumentError('Invalid layer codec kind, version or migrations.');
    }
  }
  Type get valueType => T;

  Map<String, Object?> canonical(Map<String, Object?> document) =>
      copyLayerDocument(encode(decode(document)));
}

/// Persists configuration only. Runtime readiness is established by the source
/// after attachment, never inferred from a saved document.
final class GeoLayerCodec {
  final GeoLayerController layers;
  final int maxDocumentBytes;
  final _codecs = <String, GeoLayerConfigurationCodec<Object>>{};
  GeoLayerCodec(this.layers, {this.maxDocumentBytes = 8 * 1024 * 1024}) {
    if (maxDocumentBytes < 1) {
      throw ArgumentError('Document budget must be positive.');
    }
  }

  Registration register<T extends Object>(GeoLayerConfigurationCodec<T> codec) {
    if (codec.kind == 'group' || _codecs.containsKey(codec.kind)) {
      throw StateError('Layer kind ${codec.kind} already has a codec.');
    }
    _codecs[codec.kind] = codec;
    return Registration(() {
      if (identical(_codecs[codec.kind], codec)) _codecs.remove(codec.kind);
    });
  }

  T configuration<T extends Object>(String layerId) {
    final layer = layers.layer(layerId);
    final codec = _codecs[layer.kind];
    if (codec == null ||
        codec.valueType != T ||
        codec.schemaVersion != layer.configurationVersion) {
      throw StateError('No compatible configuration codec for $layerId.');
    }
    return codec.decode(layer.configuration) as T;
  }

  Map<String, Object?> encode() => copyLayerDocument(
    {
      'schemaVersion': 1,
      'layers': [
        for (final layer in layers.snapshot)
          {
            'id': layer.id,
            'owner': layer.owner,
            'kind': layer.kind,
            'parentId': layer.parentId,
            'visible': layer.visible,
            'queryable': layer.queryable,
            'opacity': layer.opacity,
            'capabilities': layer.capabilities.map((c) => c.name).toList()
              ..sort(),
            'sourceReference': layer.sourceReference,
            'sourceRevision': layer.sourceRevision,
            'styleRevision': layer.styleRevision,
            'configurationVersion': layer.configurationVersion,
            'configuration': layer.configuration,
            'policies': {
              'queryWhenHidden': layer.policies.queryWhenHidden,
              'retention': layer.policies.retention.name,
              'simulation': layer.policies.simulation.name,
            },
            'filter': {
              'minimumDistance': layer.filter.minimumDistance,
              'maximumDistance': layer.filter.maximumDistance,
              'minimumMetresPerPixel': layer.filter.minimumMetresPerPixel,
              'maximumMetresPerPixel': layer.filter.maximumMetresPerPixel,
              'start': layer.filter.start?.toUtc().toIso8601String(),
              'end': layer.filter.end?.toUtc().toIso8601String(),
            },
            'attribution': layer.status.attribution,
            if (layer.status.coverage case final coverage?)
              'coverage': {
                'bounds': coverage.bounds?.toList(),
                'start': coverage.start?.toUtc().toIso8601String(),
                'end': coverage.end?.toUtc().toIso8601String(),
                'minimumAltitude': coverage.minimumAltitude,
                'maximumAltitude': coverage.maximumAltitude,
              },
          },
      ],
    },
    maxBytes: maxDocumentBytes,
    immutable: false,
  );

  /// Validates and decodes the whole candidate before touching live state.
  void decode(Map<String, Object?> document, {int? expectedRevision}) {
    final revision = expectedRevision ?? layers.revision;
    final json = copyLayerDocument(document, maxBytes: maxDocumentBytes);
    if (json['schemaVersion'] != 1 || json['layers'] is! List) {
      throw ArgumentError('Unsupported layer document schema.');
    }
    final candidate = <GeoLayer>[];
    try {
      for (final value in json['layers'] as List) {
        if (value is! Map<String, Object?>) {
          throw ArgumentError('Invalid layer entry.');
        }
        final kind = value['kind'] as String;
        var version = value['configurationVersion'] as int;
        var configuration = value['configuration'] as Map<String, Object?>;
        final codec = _codecs[kind];
        String? issue;
        if (kind == 'group' && version == 1) {
          if (configuration.isNotEmpty) {
            throw ArgumentError('Groups do not have custom configuration.');
          }
        } else if (codec == null) {
          issue = 'Layer kind $kind is not installed.';
        } else if (version > codec.schemaVersion) {
          issue = 'Layer kind $kind requires schema $version.';
        } else {
          var upgraded = configuration;
          var upgradedVersion = version;
          while (upgradedVersion < codec.schemaVersion) {
            final migration = codec.migrations[upgradedVersion];
            if (migration == null) {
              issue = 'No migration from $kind schema $upgradedVersion.';
              break;
            }
            upgraded = copyLayerDocument(
              migration(upgraded),
              maxBytes: maxDocumentBytes,
            );
            upgradedVersion++;
          }
          if (issue == null) {
            configuration = codec.canonical(upgraded);
            version = upgradedVersion;
          }
        }
        final policies = value['policies'] as Map<String, Object?>;
        final filter = value['filter'] as Map<String, Object?>;
        final coverage = value['coverage'] as Map<String, Object?>?;
        candidate.add(
          GeoLayer(
            id: value['id'] as String,
            owner: value['owner'] as String,
            kind: kind,
            parentId: value['parentId'] as String?,
            visible: value['visible'] as bool,
            queryable: value['queryable'] as bool,
            opacity: (value['opacity'] as num).toDouble(),
            capabilities: {
              for (final name in value['capabilities'] as List)
                GeoLayerCapability.values.byName(name as String),
            },
            sourceReference: value['sourceReference'] as String?,
            sourceRevision: value['sourceRevision'] as String?,
            styleRevision: value['styleRevision'] as String?,
            configurationVersion: version,
            configuration: configuration,
            configurationIssue: issue,
            policies: GeoLayerPolicies(
              queryWhenHidden: policies['queryWhenHidden'] as bool,
              retention: GeoHiddenRetention.values.byName(
                policies['retention'] as String,
              ),
              simulation: GeoHiddenSimulation.values.byName(
                policies['simulation'] as String,
              ),
            ),
            filter: GeoLayerFilter(
              minimumDistance: (filter['minimumDistance'] as num?)?.toDouble(),
              maximumDistance: (filter['maximumDistance'] as num?)?.toDouble(),
              minimumMetresPerPixel: (filter['minimumMetresPerPixel'] as num?)
                  ?.toDouble(),
              maximumMetresPerPixel: (filter['maximumMetresPerPixel'] as num?)
                  ?.toDouble(),
              start: filter['start'] == null
                  ? null
                  : DateTime.parse(filter['start'] as String).toUtc(),
              end: filter['end'] == null
                  ? null
                  : DateTime.parse(filter['end'] as String).toUtc(),
            ),
            status: GeoLayerStatus(
              attribution: (value['attribution'] as List).cast<String>(),
              coverage: coverage == null ? null : _coverage(coverage),
            ),
          ),
        );
      }
    } on TypeError {
      throw ArgumentError('Layer document fields have invalid types.');
    } on FormatException {
      throw ArgumentError('Layer document fields have invalid formats.');
    }
    layers.transact(revision, (edit) => edit.replaceAll(candidate));
  }

  GeoLayerCoverage _coverage(Map<String, Object?> value) {
    final bounds = value['bounds'] as List?;
    if (bounds != null && bounds.length != 4) {
      throw ArgumentError('Layer bounds require four coordinates.');
    }
    return GeoLayerCoverage(
      bounds: bounds == null
          ? null
          : GeographicRectangle.fromList(
              bounds.map((v) => (v as num).toDouble()).toList(),
            ),
      start: value['start'] == null
          ? null
          : DateTime.parse(value['start'] as String).toUtc(),
      end: value['end'] == null
          ? null
          : DateTime.parse(value['end'] as String).toUtc(),
      minimumAltitude: (value['minimumAltitude'] as num?)?.toDouble(),
      maximumAltitude: (value['maximumAltitude'] as num?)?.toDouble(),
    );
  }
}
