import 'dart:math' as math;
import '../geodesy.dart';
import '../tiling.dart';
import 'document.dart';

enum GeoLayerCapability { opacity, reorder, query, refresh, offline }

enum GeoLayerLifecycle { registered, attaching, attached, suspended, detached }

enum GeoLayerDataState {
  unavailable,
  loading,
  partial,
  ready,
  stale,
  failed,
  empty,
}

enum GeoHiddenRetention { retain, release }

enum GeoHiddenSimulation { continueRunning, pause }

final class GeoLayerPolicies {
  final bool queryWhenHidden;
  final GeoHiddenRetention retention;
  final GeoHiddenSimulation simulation;
  const GeoLayerPolicies({
    this.queryWhenHidden = false,
    this.retention = GeoHiddenRetention.retain,
    this.simulation = GeoHiddenSimulation.continueRunning,
  });
}

/// View filtering does not change data readiness or simulation admission.
final class GeoLayerFilter {
  final double? minimumDistance,
      maximumDistance,
      minimumMetresPerPixel,
      maximumMetresPerPixel;
  final DateTime? start, end;
  const GeoLayerFilter({
    this.minimumDistance,
    this.maximumDistance,
    this.minimumMetresPerPixel,
    this.maximumMetresPerPixel,
    this.start,
    this.end,
  });
  bool matches({
    required double distance,
    required double metresPerPixel,
    required DateTime time,
  }) {
    if (!distance.isFinite ||
        distance < 0 ||
        !metresPerPixel.isFinite ||
        metresPerPixel <= 0) {
      throw ArgumentError(
        'View distance and scale must be finite and in range.',
      );
    }
    return (minimumDistance == null || distance >= minimumDistance!) &&
        (maximumDistance == null || distance <= maximumDistance!) &&
        (minimumMetresPerPixel == null ||
            metresPerPixel >= minimumMetresPerPixel!) &&
        (maximumMetresPerPixel == null ||
            metresPerPixel <= maximumMetresPerPixel!) &&
        (start == null || !time.isBefore(start!)) &&
        (end == null || !time.isAfter(end!));
  }

  void validate() {
    for (final (minimum, maximum) in [
      (minimumDistance, maximumDistance),
      (minimumMetresPerPixel, maximumMetresPerPixel),
    ]) {
      if ((minimum != null && (!minimum.isFinite || minimum < 0)) ||
          (maximum != null && (!maximum.isFinite || maximum < 0)) ||
          (minimum != null && maximum != null && minimum > maximum)) {
        throw ArgumentError('Invalid layer distance or scale filter.');
      }
    }
    if (start != null && end != null && start!.isAfter(end!)) {
      throw ArgumentError('Invalid layer time filter.');
    }
  }
}

final class GeoLayerFailure {
  final String code, message;
  final bool retryable;
  const GeoLayerFailure({
    required this.code,
    required this.message,
    this.retryable = false,
  });
}

/// Geographic bounds use radians and preserve west > east at the dateline.
/// Null bounds mean the provider has not supplied spatial coverage.
final class GeoLayerCoverage {
  final GeographicRectangle? bounds;
  final DateTime? start, end;
  final double? minimumAltitude, maximumAltitude;
  const GeoLayerCoverage({
    this.bounds,
    this.start,
    this.end,
    this.minimumAltitude,
    this.maximumAltitude,
  });

  bool? contains(Geodetic position, {DateTime? at}) {
    if (at != null &&
        ((start != null && at.isBefore(start!)) ||
            (end != null && at.isAfter(end!)))) {
      return false;
    }
    if ((minimumAltitude != null && position.height < minimumAltitude!) ||
        (maximumAltitude != null && position.height > maximumAltitude!)) {
      return false;
    }
    final rectangle = bounds;
    if (rectangle == null) return null;
    final longitude = (position.longitude + math.pi) % (2 * math.pi) - math.pi;
    final insideLongitude = rectangle.west <= rectangle.east
        ? longitude >= rectangle.west && longitude <= rectangle.east
        : longitude >= rectangle.west || longitude <= rectangle.east;
    return insideLongitude &&
        position.latitude >= rectangle.south &&
        position.latitude <= rectangle.north;
  }

  void validate() {
    final r = bounds;
    if (r != null &&
        (r.toList().any((v) => !v.isFinite) ||
            r.west.abs() > math.pi ||
            r.east.abs() > math.pi ||
            r.south < -math.pi / 2 ||
            r.north > math.pi / 2 ||
            r.south > r.north)) {
      throw ArgumentError('Invalid geographic layer bounds.');
    }
    if ((start != null && end != null && start!.isAfter(end!)) ||
        (minimumAltitude != null && !minimumAltitude!.isFinite) ||
        (maximumAltitude != null && !maximumAltitude!.isFinite) ||
        (minimumAltitude != null &&
            maximumAltitude != null &&
            minimumAltitude! > maximumAltitude!)) {
      throw ArgumentError('Invalid layer coverage interval.');
    }
  }
}

final class GeoLayerStatus {
  final GeoLayerLifecycle lifecycle;
  final GeoLayerDataState data;
  final GeoLayerCoverage? coverage;
  final List<String> attribution;
  final GeoLayerFailure? failure;
  GeoLayerStatus({
    this.lifecycle = GeoLayerLifecycle.registered,
    this.data = GeoLayerDataState.unavailable,
    this.coverage,
    Iterable<String> attribution = const [],
    this.failure,
  }) : attribution = List.unmodifiable(attribution);
}

final class GeoLayer {
  final String id, owner, kind;
  final String? parentId, sourceReference, sourceRevision, styleRevision;
  final bool visible, queryable;
  final double opacity;
  final Set<GeoLayerCapability> capabilities;
  final GeoLayerStatus status;
  final GeoLayerPolicies policies;
  final GeoLayerFilter filter;
  final int configurationVersion;
  final Map<String, Object?> configuration;
  final String? configurationIssue;

  GeoLayer({
    required this.id,
    required this.owner,
    required this.kind,
    this.parentId,
    this.visible = true,
    this.queryable = true,
    this.opacity = 1,
    Set<GeoLayerCapability> capabilities = const {},
    GeoLayerStatus? status,
    this.policies = const GeoLayerPolicies(),
    this.filter = const GeoLayerFilter(),
    this.sourceReference,
    this.sourceRevision,
    this.styleRevision,
    this.configurationVersion = 1,
    Map<String, Object?> configuration = const {},
    this.configurationIssue,
  }) : capabilities = Set.unmodifiable(capabilities),
       status = status ?? GeoLayerStatus(),
       configuration = copyLayerDocument(configuration);

  bool get isGroup => kind == 'group';

  GeoLayer copyWith({
    String? parentId,
    bool clearParent = false,
    bool? visible,
    bool? queryable,
    double? opacity,
    GeoLayerStatus? status,
    GeoLayerPolicies? policies,
    GeoLayerFilter? filter,
    String? sourceReference,
    String? sourceRevision,
    String? styleRevision,
    int? configurationVersion,
    Map<String, Object?>? configuration,
    String? configurationIssue,
    bool clearConfigurationIssue = false,
  }) => GeoLayer(
    id: id,
    owner: owner,
    kind: kind,
    parentId: clearParent ? null : parentId ?? this.parentId,
    visible: visible ?? this.visible,
    queryable: queryable ?? this.queryable,
    opacity: opacity ?? this.opacity,
    capabilities: capabilities,
    status: status ?? this.status,
    policies: policies ?? this.policies,
    filter: filter ?? this.filter,
    sourceReference: sourceReference ?? this.sourceReference,
    sourceRevision: sourceRevision ?? this.sourceRevision,
    styleRevision: styleRevision ?? this.styleRevision,
    configurationVersion: configurationVersion ?? this.configurationVersion,
    configuration: configuration ?? this.configuration,
    configurationIssue: clearConfigurationIssue
        ? null
        : configurationIssue ?? this.configurationIssue,
  );
}
