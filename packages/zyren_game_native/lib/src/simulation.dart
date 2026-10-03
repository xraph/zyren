part of '../zyren_game_native.dart';

final _simulationOwners = Expando<GameSimulation>('game world owner');

/// The same native world and session serve headless training and visible play.
final class GameSimulation {
  final GameSession session;
  final PhysicsPlugin physics;
  final bool ownsWorld;
  Future<void>? _closing;
  PhysicsWorld get world => physics.world;
  factory GameSimulation({
    required CompiledGameProject project,
    required int seed,
    PhysicsPlugin? physics,
    List<GameSystem> systems = const [],
    bool ownsWorld = false,
    int maxCatchUpSteps = 8,
    Set<String> availableCapabilities = const {},
  }) {
    if (project.fixedHz < 10) {
      throw ArgumentError('Native game rates must be within 10..240 Hz.');
    }
    final missing = project.capabilityRequirements
        .where((c) => !availableCapabilities.contains(c))
        .toList();
    if (missing.isNotEmpty) {
      throw UnsupportedError(
        'Missing game capabilities: ${missing.join(', ')}.',
      );
    }
    final created = physics == null;
    final plugin =
        physics ??
        PhysicsPlugin(
          world: PhysicsWorld(fixedStep: 1.0 / project.fixedHz),
          externallyDriven: true,
          interpolate: false,
          maxFrameDelta: 1.0 / project.fixedHz,
        );
    try {
      if (plugin.world.isClosed) throw StateError('Physics world is closed.');
      if (!plugin.externallyDriven) {
        throw ArgumentError('Game physics must be externally driven.');
      }
      if ((plugin.world.fixedStep - 1.0 / project.fixedHz).abs() > 1e-12) {
        throw ArgumentError('Physics and compiled game rates differ.');
      }
      if (plugin.maxFrameDelta < 1.0 / project.fixedHz) {
        throw ArgumentError('Physics frame delta must admit a full game step.');
      }
      if (_simulationOwners[plugin.world] != null) {
        throw StateError('World already belongs to a game simulation.');
      }
      final session = GameSession(
        project: project,
        seed: seed,
        maxCatchUpSteps: maxCatchUpSteps,
        systems: [...systems, GamePhysicsDriver(plugin)],
      );
      final simulation = GameSimulation._(
        session,
        plugin,
        created || ownsWorld,
      );
      _simulationOwners[plugin.world] = simulation;
      return simulation;
    } catch (_) {
      if (created) plugin.world.close();
      rethrow;
    }
  }
  GameSimulation._(this.session, this.physics, this.ownsWorld);
  void step() => session.step();
  int advance(double seconds) => session.advance(seconds);
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    try {
      await session.close();
    } finally {
      physics.clearBindings();
      if (identical(_simulationOwners[world], this)) {
        _simulationOwners[world] = null;
      }
      if (ownsWorld && !world.isClosed) world.close();
    }
  }
}
