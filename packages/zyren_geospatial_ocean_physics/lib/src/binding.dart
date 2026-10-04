part of 'bridge.dart';

final class _Binding {
  final PhysicsBody body;
  final BuoyancyShape shape;
  final BuoyancySolver solver;
  final double density;
  final OceanSleepSettings sleep;
  const _Binding(this.body, this.shape, this.solver, this.density, this.sleep);
}
