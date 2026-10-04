import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'bridge.dart';

/// Force phase only. Keep integration in the existing physics owner.
final class OceanBuoyancySystem extends GeoSimulationSystem {
  final OceanPhysicsBridge bridge;
  @override
  final String id;
  @override
  final Set<String> dependencies;
  OceanBuoyancySystem(
    this.bridge, {
    this.id = 'ocean.buoyancy',
    Set<String> dependencies = const {},
  }) : dependencies = Set.unmodifiable(dependencies);
  @override
  GeoSimulationPhase get phase => GeoSimulationPhase.forces;
  @override
  int get requiredHz => (1 / bridge.world.fixedStep).round();
  @override
  Future<void> step(GeoInstant instant) async {
    final batch = await bridge.prepare(instant);
    bridge.apply(batch, bridge.world.fixedStep);
  }
}
