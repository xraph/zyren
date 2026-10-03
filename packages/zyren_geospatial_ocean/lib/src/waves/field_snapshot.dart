import 'package:zyren/zyren.dart';

final class OceanBandTextures {
  /// dx, height offset, dz, horizontal Jacobian for this band.
  final GpuResource<Texture> displacement;

  /// dh/dx, dh/dz, dDx/dx, dDz/dz.
  final GpuResource<Texture> derivatives;

  /// vx, vy, vz, dDx/dz (equal to dDz/dx for this potential field).
  final GpuResource<Texture> velocity;
  final double patchMetres, unresolvedSlopeVariance;
  const OceanBandTextures({
    required this.displacement,
    required this.derivatives,
    required this.velocity,
    required this.patchMetres,
    required this.unresolvedSlopeVariance,
  });
}

/// Published only after GPU execution completes. Resources remain unchanged
/// while this is the current snapshot. Retaining a texture does not freeze it;
/// replace bindings when a later evaluation publishes and check isCurrent.
final class OceanFieldSnapshot {
  final List<OceanBandTextures> bands;
  final double seconds, meanLevel;
  final String seaStateRevision;
  final int revision, resolution, logicalPayloadBytes, dispatches;
  final bool Function() _current;
  bool get isCurrent => _current();
  OceanFieldSnapshot({
    required List<OceanBandTextures> bands,
    required this.seconds,
    required this.meanLevel,
    required this.seaStateRevision,
    required this.revision,
    required this.resolution,
    required this.logicalPayloadBytes,
    required this.dispatches,
    required bool Function() isCurrent,
  }) : bands = List.unmodifiable(bands),
       _current = isCurrent;
}
