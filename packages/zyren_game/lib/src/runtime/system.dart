part of '../../zyren_game.dart';

enum GamePhase {
  commands,
  decisions,
  controllers,
  physics,
  rules,
  sensors,
  diagnostics,
}

abstract class GameSystem {
  String get id;
  int get version => 1;
  GamePhase get phase;
  Set<String> get dependencies => const {};
  void start(GameSession session) {}
  void fixedUpdate(GameSession session);
  void pause(GameSession session) {}
  void resume(GameSession session) {}
  FutureOr<void> dispose(GameSession session) {}
}

List<GameSystem> _orderSystems(List<GameSystem> systems) {
  if (systems.length > 256) throw StateError('System limit exceeded.');
  final byId = <String, GameSystem>{};
  for (final system in systems) {
    _id(system.id);
    if (system.version < 1 || byId.containsKey(system.id)) {
      throw StateError('Invalid or duplicate system: ${system.id}.');
    }
    byId[system.id] = system;
  }
  final ordered = <GameSystem>[], visiting = <String>{}, visited = <String>{};
  void visit(GameSystem system) {
    if (visited.contains(system.id)) return;
    if (!visiting.add(system.id)) throw StateError('System dependency cycle.');
    for (final id in system.dependencies.toList()..sort()) {
      final dependency = byId[id];
      if (dependency == null) {
        throw StateError('Missing system dependency: $id.');
      }
      if (dependency.phase.index > system.phase.index) {
        throw StateError('System dependency in a later phase: $id.');
      }
      visit(dependency);
    }
    visiting.remove(system.id);
    visited.add(system.id);
    ordered.add(system);
  }

  for (final phase in GamePhase.values) {
    for (final system in systems.where((s) => s.phase == phase)) {
      visit(system);
    }
  }
  return List.unmodifiable(ordered);
}
