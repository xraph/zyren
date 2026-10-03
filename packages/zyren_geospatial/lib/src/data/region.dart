import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../tiling.dart';
import '../layers/document.dart';
import 'coverage.dart';
import 'resource_key.dart';
import 'policy.dart';

final class GeoOfflineRegion {
  final String id, authorizationPartition;
  final Map<String, String> sourceVersions;
  final Set<String> layerIds;
  final GeographicRectangle bounds;
  final int minimumLevel, maximumLevel;
  final DateTime? start, end;
  GeoOfflineRegion({
    required this.id,
    required Map<String, String> sourceVersions,
    required this.authorizationPartition,
    required Set<String> layerIds,
    required this.bounds,
    required this.minimumLevel,
    required this.maximumLevel,
    this.start,
    this.end,
  }) : sourceVersions = Map.unmodifiable(sourceVersions),
       layerIds = Set.unmodifiable(layerIds) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$').hasMatch(id) ||
        sourceVersions.isEmpty ||
        sourceVersions.length > 64 ||
        layerIds.isEmpty ||
        layerIds.length > 128 ||
        minimumLevel < 0 ||
        maximumLevel > 24 ||
        minimumLevel > maximumLevel ||
        (start != null && !start!.isUtc) ||
        (end != null && !end!.isUtc) ||
        (start != null && end != null && start!.isAfter(end!))) {
      throw ArgumentError('Invalid offline region.');
    }
    validateGeoBounds(bounds);
    for (final entry in sourceVersions.entries) {
      GeoResourceKey(
        sourceId: entry.key,
        sourceVersion: entry.value,
        authorizationPartition: authorizationPartition,
        address: 'region',
        representation: 'manifest',
        decoderVersion: 1,
      );
    }
    copyLayerDocument(toJson(), maxBytes: 65536);
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'sourceVersions': sourceVersions,
    'authorizationPartition': authorizationPartition,
    'layerIds': layerIds.toList()..sort(),
    'bounds': bounds.toList(),
    'minimumLevel': minimumLevel,
    'maximumLevel': maximumLevel,
    'start': start?.toIso8601String(),
    'end': end?.toIso8601String(),
  };
  factory GeoOfflineRegion.fromJson(Map<String, Object?> value) =>
      GeoOfflineRegion(
        id: value['id'] as String,
        sourceVersions: (value['sourceVersions'] as Map).cast<String, String>(),
        authorizationPartition: value['authorizationPartition'] as String,
        layerIds: (value['layerIds'] as List).cast<String>().toSet(),
        bounds: GeographicRectangle.fromList(
          (value['bounds'] as List).map((v) => (v as num).toDouble()).toList(),
        ),
        minimumLevel: value['minimumLevel'] as int,
        maximumLevel: value['maximumLevel'] as int,
        start: value['start'] == null
            ? null
            : DateTime.parse(value['start'] as String),
        end: value['end'] == null
            ? null
            : DateTime.parse(value['end'] as String),
      );
}

final class GeoPlannedResource {
  final GeoResourceKey key;
  final int estimatedBytes;
  final List<GeoResourceKey> dependencies;
  GeoPlannedResource({
    required this.key,
    required this.estimatedBytes,
    Iterable<GeoResourceKey> dependencies = const [],
  }) : dependencies = List.unmodifiable(dependencies.take(1025)) {
    if (estimatedBytes < 1 ||
        estimatedBytes > 512 * 1024 * 1024 ||
        this.dependencies.length > 1024 ||
        this.dependencies.toSet().length != this.dependencies.length ||
        this.dependencies.contains(key)) {
      throw ArgumentError('Invalid resource dependency declaration.');
    }
  }
  Map<String, Object?> toJson() => {
    'key': key.toJson(),
    'estimatedBytes': estimatedBytes,
    'dependencies': dependencies.map((k) => k.toJson()).toList(),
  };
  factory GeoPlannedResource.fromJson(Map<String, Object?> value) =>
      GeoPlannedResource(
        key: GeoResourceKey.fromJson(value['key'] as Map<String, Object?>),
        estimatedBytes: value['estimatedBytes'] as int,
        dependencies: (value['dependencies'] as List).map(
          (v) => GeoResourceKey.fromJson(v as Map<String, Object?>),
        ),
      );
}

final class GeoRegionPlan {
  final GeoOfflineRegion region;
  final List<GeoPlannedResource> resources;
  final List<String> credits;
  final bool coverageComplete;
  final int maxResources, maxBytes;
  late final String digest = sha256
      .convert(utf8.encode(jsonEncode(toJson())))
      .toString();
  int get estimatedBytes => resources.fold(0, (n, r) => n + r.estimatedBytes);
  GeoRegionPlan({
    required this.region,
    required Iterable<GeoPlannedResource> resources,
    required this.coverageComplete,
    Iterable<String> credits = const [],
    this.maxResources = 4096,
    this.maxBytes = 256 * 1024 * 1024,
  }) : resources = List.unmodifiable(
         resources.take(maxResources.clamp(0, 10000) + 1),
       ),
       credits = List.unmodifiable(credits.take(257)) {
    if (maxResources < 1 ||
        maxResources > 10000 ||
        maxBytes < 1 ||
        maxBytes > 1 << 40 ||
        this.resources.isEmpty ||
        this.resources.length > maxResources ||
        estimatedBytes > maxBytes) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    if (this.credits.length > 256 ||
        this.resources.fold<int>(0, (n, r) => n + r.dependencies.length) >
            65536) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    final keys = this.resources.map((r) => r.key).toSet();
    if (keys.length != this.resources.length ||
        this.resources.any(
          (r) =>
              r.key.authorizationPartition != region.authorizationPartition ||
              region.sourceVersions[r.key.sourceId] != r.key.sourceVersion ||
              r.dependencies.any((k) => !keys.contains(k)),
        ) ||
        !keys
            .map((k) => k.sourceId)
            .toSet()
            .containsAll(region.sourceVersions.keys)) {
      throw ArgumentError(
        'Region resources must include every declared source and dependency in the same authorization partition.',
      );
    }
    final incoming = {
      for (final r in this.resources) r.key: r.dependencies.length,
    };
    final children = <GeoResourceKey, List<GeoResourceKey>>{};
    for (final r in this.resources) {
      for (final dep in r.dependencies) {
        (children[dep] ??= []).add(r.key);
      }
    }
    final ready = incoming.keys.where((k) => incoming[k] == 0).toList();
    var visited = 0;
    for (var i = 0; i < ready.length; i++) {
      visited++;
      for (final k in children[ready[i]] ?? <GeoResourceKey>[]) {
        incoming[k] = incoming[k]! - 1;
        if (incoming[k] == 0) ready.add(k);
      }
    }
    if (visited != keys.length) {
      throw ArgumentError('Region dependencies must be acyclic.');
    }
    copyLayerDocument(toJson(), maxBytes: 4 * 1024 * 1024);
  }
  Map<String, Object?> toJson() => {
    'schema': 1,
    'region': region.toJson(),
    'resources': resources.map((r) => r.toJson()).toList(),
    'coverageComplete': coverageComplete,
    'credits': credits,
    'maxResources': maxResources,
    'maxBytes': maxBytes,
  };
  factory GeoRegionPlan.fromJson(Map<String, Object?> value) {
    try {
      if (value['schema'] != 1) {
        throw const FormatException('Unsupported region plan.');
      }
      return GeoRegionPlan(
        region: GeoOfflineRegion.fromJson(
          value['region'] as Map<String, Object?>,
        ),
        resources: (value['resources'] as List).map(
          (v) => GeoPlannedResource.fromJson(v as Map<String, Object?>),
        ),
        coverageComplete: value['coverageComplete'] as bool,
        credits: (value['credits'] as List).cast<String>(),
        maxResources: value['maxResources'] as int,
        maxBytes: value['maxBytes'] as int,
      );
    } catch (e) {
      throw GeoDataException(GeoDataError.corrupt, cause: e);
    }
  }
}

enum GeoRegionJobState {
  planned,
  downloading,
  paused,
  verifying,
  complete,
  failed,
}

final class GeoRegionManifest {
  final GeoRegionPlan plan;
  final Set<GeoResourceKey> verifiedKeys;
  final Map<GeoResourceKey, GeoDataError> failures;
  final DateTime verifiedAt;
  final bool verificationFinished;
  GeoRegionManifest({
    required this.plan,
    required Set<GeoResourceKey> verifiedKeys,
    required Map<GeoResourceKey, GeoDataError> failures,
    required this.verifiedAt,
    this.verificationFinished = true,
  }) : verifiedKeys = Set.unmodifiable(verifiedKeys),
       failures = Map.unmodifiable(failures);
  Set<GeoResourceKey> get missingKeys => Set.unmodifiable(
    plan.resources.map((r) => r.key).toSet().difference(verifiedKeys),
  );
  bool get complete =>
      verificationFinished &&
      plan.coverageComplete &&
      missingKeys.isEmpty &&
      failures.isEmpty;
  Map<String, Object?> toJson() => {
    'schema': 1,
    'plan': plan.toJson(),
    'verified': verifiedKeys.map((k) => k.digest).toList()..sort(),
    'failures': {for (final e in failures.entries) e.key.digest: e.value.name},
    'verifiedAt': verifiedAt.toIso8601String(),
    'complete': complete,
  };
}
