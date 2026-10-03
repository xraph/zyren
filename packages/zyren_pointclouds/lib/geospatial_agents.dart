/// Optional source-coordinate and live 3D Tiles context for agent providers.
library;

import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';

/// A declared source-to-ECEF transform. Importing WKT alone never establishes
/// this mapping. Use the same transform group for rendering and query context.
final class RealityGeospatialReference {
  final GeospatialReference reference;
  final Mat4 sourceToEcef;
  final String sourceCrs;
  RealityGeospatialReference({
    required this.sourceToEcef,
    required this.sourceCrs,
    this.reference = const GeospatialReference(),
  }) {
    final m = sourceToEcef.storage;
    if (sourceCrs.isEmpty ||
        sourceCrs.length > 65536 ||
        m.any((value) => !value.isFinite) ||
        m[3] != 0 ||
        m[7] != 0 ||
        m[11] != 0 ||
        m[15] != 1) {
      throw ArgumentError(
        'A declared CRS and affine source transform are required.',
      );
    }
    sourceToEcef.inverted();
  }
  factory RealityGeospatialReference.ecef({
    GeospatialReference reference = const GeospatialReference(),
  }) => RealityGeospatialReference(
    sourceToEcef: Mat4.identity(),
    sourceCrs: 'ECEF metres on the supplied ellipsoid',
    reference: reference,
  );
  factory RealityGeospatialReference.eastNorthUp(
    Geodetic origin, {
    GeospatialReference reference = const GeospatialReference(),
  }) => RealityGeospatialReference(
    sourceToEcef: reference.ellipsoid.eastNorthUpFrame(
      reference.toEcef(origin),
    ),
    sourceCrs: 'Local east/north/up metres',
    reference: reference,
  );
  Vec3 toEcef(Vec3 point) {
    final m = sourceToEcef.storage;
    return Vec3(
      m[0] * point.x + m[4] * point.y + m[8] * point.z + m[12],
      m[1] * point.x + m[5] * point.y + m[9] * point.z + m[13],
      m[2] * point.x + m[6] * point.y + m[10] * point.z + m[14],
    );
  }

  Group createGroup({String name = 'source geospatial frame'}) =>
      _ReferenceGroup(sourceToEcef, name: name);
  Map<String, Object?> get description => {
    'sourceCrs': sourceCrs,
    'sourceToEcef': sourceToEcef.storage,
    'ellipsoidRadiiMetres': [
      reference.ellipsoid.x,
      reference.ellipsoid.y,
      reference.ellipsoid.z,
    ],
    'mapping': 'host-declared-affine',
  };
  Map<String, Object?> describePoint(Vec3 point) {
    final ecef = toEcef(point), geo = reference.fromEcef(toEcef(point));
    return {
      'ecefMetres': [ecef.x, ecef.y, ecef.z],
      'longitudeDegrees': geo.longitudeDegrees,
      'latitudeDegrees': geo.latitudeDegrees,
      'ellipsoidHeightMetres': geo.height,
    };
  }
}

final class _ReferenceGroup extends Group {
  final Mat4 transform;
  _ReferenceGroup(this.transform, {super.name});
  @override
  Mat4 get localMatrix => transform * super.localMatrix;
}

/// Explicit host association. A source URI alone does not prove tile membership.
final class SourceTileLink {
  final String tileId;
  final int? featureId;
  final String? featureLabel;
  final int featureSet;
  SourceTileLink({
    required this.tileId,
    this.featureId,
    this.featureLabel,
    this.featureSet = 0,
  }) {
    if (tileId.isEmpty ||
        tileId.length > 2048 ||
        featureId != null && featureId! < 0 ||
        featureSet < 0 ||
        (featureLabel?.length ?? 0) > 1024) {
      throw ArgumentError('Invalid source tile association.');
    }
  }
}

final class RealityTilesContext {
  final Tiles3DStreamer streamer;
  final SourceTileLink? Function((Uri, String, int) source)? linkForSource;
  String? _state;
  int _revision = 0;
  RealityTilesContext(this.streamer, {this.linkForSource});

  /// Tracks live loading and visible tile replacements for registry stale guards.
  int get revision {
    final state = jsonEncode([
      snapshot(),
      for (final entry in streamer.visible.entries)
        [entry.key, identityHashCode(entry.value)],
      for (final entry in streamer.selected.entries)
        [entry.key, entry.value.geometricError],
    ]);
    if (_state != state) {
      _state = state;
      _revision++;
    }
    return _revision;
  }

  Map<String, Object?> snapshot() {
    final stats = streamer.stats;
    return {
      'tilesetUri': streamer.tileset.sourceUri.toString(),
      'tilesetVersion': streamer.tileset.version,
      'selectedTiles': stats.selectedTiles,
      'visibleTiles': stats.visibleTiles,
      'activeRequests': stats.activeRequests,
      'cachedBytes': stats.cachedBytes,
      'reservedBytes': stats.reservedBytes,
      'residentPayloadBytes': stats.residentBytes,
      'physicalGpuResidentBytes': null,
      'budgetLimited': stats.budgetLimited,
      'transitioning': streamer.isTransitioning,
      'visibleTileIds': streamer.visible.keys.take(128).toList(),
      'visibleIdsTruncated': streamer.visible.length > 128,
      'failures': [
        for (final f in streamer.failures.take(32))
          {
            'tileId': f.tileId,
            'code': f.code.name,
            'attempts': f.attempts,
            'httpStatus': f.httpStatus,
          },
      ],
      'failuresTruncated': streamer.failures.length > 32,
    };
  }

  Map<String, Object?>? sourceLink((Uri, String, int) source) {
    final link = linkForSource?.call(source);
    if (link == null) return null;
    final selected = streamer.selected[link.tileId];
    final resident = streamer.visible[link.tileId];
    final matches = resident is TileModelInstance3D && link.featureId != null
        ? resident.features
              .where(
                (feature) =>
                    feature.id == link.featureId &&
                    (link.featureLabel == null
                        ? feature.setIndex == link.featureSet
                        : feature.label == link.featureLabel),
              )
              .toList()
        : <TileFeature3D>[];
    final feature = matches.length == 1 ? matches.single : null;
    final properties = feature?.properties;
    final tooLarge =
        properties != null &&
        utf8.encode(jsonEncode(properties)).length > 16384;
    return {
      'tilesetUri': streamer.tileset.sourceUri.toString(),
      'tilesetVersion': streamer.tileset.version,
      'tileId': link.tileId,
      'featureId': link.featureId,
      'featureLabel': link.featureLabel,
      'featureSet': link.featureSet,
      'visible': streamer.visible.containsKey(link.tileId),
      'selected': selected != null,
      'geometricError': selected?.geometricError,
      'mapping': 'host-declared-source-association',
      'featureIdentityVerified': feature != null,
      'featureMetadataVerified':
          properties != null && properties.isNotEmpty && !tooLarge,
      'featureProperties': tooLarge ? null : properties,
      'featurePropertiesTruncated': tooLarge,
      'featureMappingAmbiguous': matches.length > 1,
    };
  }
}

/// Decorates the shared point/splat provider without changing its permissions,
/// revision rules or source identities. Missing domain mappings remain null.
final class RealityContextAgentProvider extends AgentProvider {
  final AgentProvider inner;
  final RealityGeospatialReference? geospatial;
  final RealityTilesContext? tiles;
  RealityContextAgentProvider({
    required this.inner,
    this.geospatial,
    this.tiles,
  });
  @override
  String get id => inner.id;
  @override
  String get instanceId => inner.instanceId;
  @override
  String get version => inner.version;
  @override
  int get revision => inner.revision + (tiles?.revision ?? 0);
  @override
  List<Map<String, Object?>> get resources => inner.resources;
  @override
  List<AgentTool> get tools => inner.tools;
  @override
  Map<String, Object?> get capabilities => {
    ...inner.capabilities,
    'geospatialContext': geospatial == null
        ? 'unknown'
        : 'host-declared-source-transform',
    'tiles3dContext': tiles == null ? 'unknown' : 'live-streamer',
  };
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    final result = await inner.invoke(tool, arguments, context);
    context.checkCancelled();
    if (!result.isSuccess) return result;
    final data = Map<String, Object?>.from(result.data);
    data['geospatialReference'] = geospatial?.description;
    data['tiles3d'] = tiles?.snapshot();
    if (data['coverage'] is Map) {
      data['coverage'] = {
        ...(data['coverage'] as Map).cast<String, Object?>(),
        'geospatialContext': capabilities['geospatialContext'],
        'tiles3dContext': capabilities['tiles3dContext'],
      };
    }
    if (data['hits'] case final List hits) {
      data['hits'] = [
        for (final raw in hits) _enrich((raw as Map).cast<String, Object?>()),
      ];
    }
    return AgentResult(
      result.status,
      data: data,
      message: result.message,
      revision: revision,
      affectedIds: result.affectedIds,
    );
  }

  Map<String, Object?> _enrich(Map<String, Object?> hit) {
    final point = hit['sourcePoint'] ?? hit['sourceMean'];
    final result = Map<String, Object?>.from(hit);
    result['geospatial'] =
        geospatial != null && point is List && point.length == 3
        ? geospatial!.describePoint(
            Vec3(
              (point[0] as num).toDouble(),
              (point[1] as num).toDouble(),
              (point[2] as num).toDouble(),
            ),
          )
        : null;
    final uri = hit['sourceUri'],
        version = hit['sourceVersion'],
        ordinal = hit['recordIndex'];
    result['tile'] = uri is String && version is String && ordinal is int
        ? tiles?.sourceLink((Uri.parse(uri), version, ordinal))
        : null;
    return result;
  }
}
