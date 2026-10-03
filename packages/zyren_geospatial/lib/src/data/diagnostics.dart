import 'dart:async';
import '../extensions/context.dart';
import '../extensions/extension.dart';
import '../extensions/registry.dart';
import 'field_source.dart';
import 'policy.dart';
import 'request_pool.dart';
import 'resolver.dart';
import 'region_job.dart';
import 'resource_key.dart';
import 'store.dart';

final class GeoDataTiers {
  final int? encodedMemoryBytes,
      decodedCpuBytes,
      diskPayloadBytes,
      diskMetadataBytes,
      diskTemporaryBytes,
      pinnedBytes;
  GeoDataTiers({
    this.encodedMemoryBytes,
    this.decodedCpuBytes,
    this.diskPayloadBytes,
    this.diskMetadataBytes,
    this.diskTemporaryBytes,
    this.pinnedBytes,
  }) {
    if ([
      encodedMemoryBytes,
      decodedCpuBytes,
      diskPayloadBytes,
      diskMetadataBytes,
      diskTemporaryBytes,
      pinnedBytes,
    ].whereType<int>().any((v) => v < 0)) {
      throw ArgumentError('Known data-tier sizes cannot be negative.');
    }
  }
}

final class GeoDataSourceFailure {
  final String sourceId, sourceVersion, keyDigest;
  final GeoDataError code;
  GeoDataSourceFailure(GeoResourceKey key, this.code)
    : sourceId = key.sourceId,
      sourceVersion = key.sourceVersion,
      keyDigest = key.digest;
}

final class GeoDataDiagnosticsSnapshot {
  final GeoDataTiers? tiers;
  final GeoDataError? storeFailure;
  final GeoRequestPoolStats requests;
  final List<GeoDataSourceFailure> failures;
  final Map<String, GeoRegionProgress> regions;
  final int transportAttempts, cacheAdmissionFailures;

  /// This service measures data ownership, not physical GPU residency.
  int? get physicalGpuResidentBytes => null;
  GeoDataDiagnosticsSnapshot({
    required this.tiers,
    required this.storeFailure,
    required this.requests,
    required Iterable<GeoDataSourceFailure> failures,
    required Map<String, GeoRegionProgress> regions,
    required this.transportAttempts,
    required this.cacheAdmissionFailures,
  }) : failures = List.unmodifiable(failures),
       regions = Map.unmodifiable(regions);
}

/// Wrap application fetch callbacks in trackSource to report actual source work.
/// Cached success does not erase an earlier failure from a different resource.
final class GeoDataDiagnostics {
  final GeoResourceResolver resolver;
  final FutureOr<GeoDataTiers> Function()? inspectTiers;
  final Iterable<GeoRegionJob> Function()? jobs;
  final int maxFailures;
  final _failures = <String, GeoDataSourceFailure>{};
  int _transportAttempts = 0;
  GeoDataDiagnostics({
    required this.resolver,
    this.inspectTiers,
    this.jobs,
    this.maxFailures = 256,
  }) {
    if (maxFailures < 1 || maxFailures > 4096) {
      throw ArgumentError('Invalid diagnostic history limit.');
    }
  }
  Future<GeoResource> trackSource(
    GeoResourceKey key,
    Future<GeoResource> Function() fetch,
  ) async {
    _transportAttempts++;
    try {
      final value = await fetch();
      _failures.remove(key.digest);
      return value;
    } catch (error) {
      final failure = error is GeoDataException
          ? error
          : GeoDataException(GeoDataError.invalidResponse, cause: error);
      _failures.remove(key.digest);
      if (_failures.length >= maxFailures) {
        _failures.remove(_failures.keys.first);
      }
      _failures[key.digest] = GeoDataSourceFailure(key, failure.code);
      throw failure;
    }
  }

  Future<GeoDataDiagnosticsSnapshot> snapshot() async {
    GeoDataTiers? tiers;
    GeoDataError? failure;
    try {
      tiers = await inspectTiers?.call();
    } on GeoDataException catch (error) {
      failure = error.code;
    } catch (_) {
      failure = GeoDataError.invalidResponse;
    }
    final regions = <String, GeoRegionProgress>{};
    for (final job in (jobs?.call() ?? <GeoRegionJob>[]).take(257)) {
      if (regions.length >= 256) {
        throw const GeoDataException(GeoDataError.budgetExceeded);
      }
      if (job.plan != null) regions[job.plan!.region.id] = job.progress;
    }
    return GeoDataDiagnosticsSnapshot(
      tiers: tiers,
      storeFailure: failure,
      requests: resolver.pool.stats,
      failures: _failures.values,
      regions: regions,
      transportAttempts: _transportAttempts,
      cacheAdmissionFailures: resolver.cacheAdmissionFailures,
    );
  }
}

const geospatialDataStore = GeoServiceKey<GeoDataStore>('geospatial.data', 1);
const geospatialDataResolver = GeoServiceKey<GeoResourceResolver>(
  'geospatial.data.resolver',
  1,
);
const geospatialDataDiagnostics = GeoServiceKey<GeoDataDiagnostics>(
  'geospatial.data.diagnostics',
  1,
);

/// Publishes scoped services. The application retains ownership of stores,
/// resolvers, jobs and fields so several views can share their lifetimes.
final class GeoDataExtension extends GeospatialExtension {
  @override
  final String localId;
  final GeoDataStore store;
  final GeoResourceResolver resolver;
  final GeoDataDiagnostics diagnostics;
  final Map<String, GeoFieldSource<double>> fields;
  GeoDataExtension({
    this.localId = 'data',
    required this.store,
    required this.resolver,
    required this.diagnostics,
    Map<String, GeoFieldSource<double>> fields = const {},
  }) : fields = Map.unmodifiable(fields) {
    if (!identical(resolver.store, store) ||
        !identical(diagnostics.resolver, resolver) ||
        fields.length > 64 ||
        fields.keys.any(
          (id) => !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(id),
        )) {
      throw ArgumentError('Invalid shared data services.');
    }
  }
  @override
  Set<String> get exclusiveCapabilities => const {'geospatial.data'};
  @override
  void attachGeospatial(GeospatialContext context) {
    context.provide(geospatialDataStore, store);
    context.provide(geospatialDataResolver, resolver);
    context.provide(geospatialDataDiagnostics, diagnostics);
    for (final entry in fields.entries) {
      context.provide(
        GeoServiceKey<GeoFieldSource<double>>(
          'geospatial.field.${entry.key}',
          1,
        ),
        entry.value,
      );
    }
  }
}
