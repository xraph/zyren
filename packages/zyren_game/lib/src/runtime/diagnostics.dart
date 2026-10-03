part of '../../zyren_game.dart';

/// Current counters are shared through the ordinary agent/devtools transport.
final class GameDiagnostics {
  final GameSession? Function() session;
  GameDiagnostics(this.session);
  Map<String, Object?> snapshot() {
    final value = session();
    return {
      'status': value == null || value.isClosed
          ? 'missing'
          : value.fault != null
          ? 'failed'
          : value.paused
          ? 'paused'
          : 'running',
      'tick': value?.tick,
      'epoch': value?.epoch,
      'entities': value?.entities.length,
      'queuedCommands': value?.commands.length,
      'droppedSeconds': value?.droppedSeconds,
      'buildId': value?.project.buildId,
    };
  }
}
