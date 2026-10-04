import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'accuracy.dart';
import 'inversion.dart';

/// A body-fixed point and simulation instant. Its altitude does not change waves.
final class OceanQuery {
  final Vec3 positionEcef;
  final GeoInstant time;
  OceanQuery(this.positionEcef, this.time) {
    if (!positionEcef.isFinite) {
      throw ArgumentError('Query position must be finite.');
    }
  }
}

final class OceanSurfaceValue {
  final Vec3 positionEcef,
      materialEcef,
      normalEcef,
      velocityEcef,
      positionLocal,
      normalLocal,
      velocityLocal;

  /// Height along the query footpoint's ellipsoid normal, in metres.
  final double height;
  const OceanSurfaceValue({
    required this.positionEcef,
    required this.materialEcef,
    required this.normalEcef,
    required this.velocityEcef,
    required this.positionLocal,
    required this.normalLocal,
    required this.velocityLocal,
    required this.height,
  });
}

/// Failures carry provenance but no physical value or accuracy claim.
final class OceanSample {
  final OceanQuery query;
  final OceanQueryFailure? failure;
  final OceanSurfaceValue? value;
  final OceanSurfaceAccuracy? accuracy;
  final String seaStateRevision, coverageRevision, frameId;
  final int frameRevision;
  final GeoInstant? evaluatedTime;
  final Duration? age;
  final double? residual;
  OceanSample({
    required this.query,
    required this.failure,
    required this.value,
    required this.accuracy,
    required this.seaStateRevision,
    required this.coverageRevision,
    required this.frameId,
    required this.frameRevision,
    required this.evaluatedTime,
    required this.age,
    required this.residual,
  }) {
    if ((failure == null &&
            (value == null ||
                accuracy == null ||
                evaluatedTime == null ||
                age == null)) ||
        (failure != null && (value != null || accuracy != null))) {
      throw ArgumentError(
        'A physical value requires a current, admitted result.',
      );
    }
  }
  bool get available => failure == null;
  double? get height => value?.height;
}

/// Explicit procedural all-water coverage. This makes no claim about Earth's land.
final class OceanAllWaterCoverage implements GeoFieldSource<bool> {
  @override
  final String id, revision;
  const OceanAllWaterCoverage({
    this.id = 'procedural-all-water',
    this.revision = '1',
  });
  @override
  String get units => 'boolean';
  @override
  GeoHeightDatum? get datum => null;
  @override
  Future<GeoSample<bool>> sample(Geodetic coordinate, GeoInstant time) async =>
      GeoSample(
        availability: GeoSampleAvailability.available,
        value: true,
        frameId: 'body-fixed',
        frameRevision: 0,
        sourceRevision: revision,
        units: units,
        time: time,
        age: Duration.zero,
      );
}

final class OceanQueryDiagnostics {
  final int modeEvaluations, fieldBatches, gpuDispatches;

  /// Logical payload allowances, not physical heap or GPU residency measurements.
  final int workerLogicalBytes, hostLogicalBytes, gpuLogicalBytes;
  const OceanQueryDiagnostics({
    this.modeEvaluations = 0,
    this.fieldBatches = 0,
    this.gpuDispatches = 0,
    this.workerLogicalBytes = 0,
    this.hostLogicalBytes = 0,
    this.gpuLogicalBytes = 0,
  });
}
