part of '../zyren_game_native.dart';

const gameSessionService = ServiceKey<GameSession>('zyren.game.session');
final _presentationOwners = Expando<GameScenePlugin>('game presentation owner');

/// Admits elapsed time to the session; it never steps the world directly.
final class GameScenePlugin extends ScenePlugin {
  final GameSimulation simulation;
  final bool realtime;
  PluginContext? _context;
  Registration? _demand;
  GameEventSubscription? _state;
  GameRealtimeClock? _clock;
  Registration? _activity;
  GameScenePlugin(this.simulation, {this.realtime = true});
  @override
  String get id => 'zyren.game';
  @override
  Set<String> get dependencies => const {'zyren.physics'};
  @override
  void attach(PluginContext context) {
    if (_context != null || _presentationOwners[simulation] != null) {
      throw StateError('Game simulation already has a presentation driver.');
    }
    if (simulation.session.isClosed) {
      throw StateError('Game session is closed.');
    }
    if (!identical(context.service(physicsWorldService), simulation.world)) {
      throw StateError('Scene uses another physics world.');
    }
    _context = context;
    _presentationOwners[simulation] = this;
    context.provide(gameSessionService, simulation.session);
    if (realtime && context.input is ViewportActivitySource) {
      final activity = context.input! as ViewportActivitySource;
      _clock = GameRealtimeClock(simulation.session);
      _activity = activity.listenViewportActivity(_clock!.setActive);
      _clock!.setActive(activity.viewportActive);
    }
    _state = simulation.session.listenState(_syncDemand);
    _syncDemand();
  }

  void _syncDemand() {
    final context = _context;
    if (context == null) return;
    if (realtime &&
        !simulation.session.paused &&
        !simulation.session.isClosed &&
        simulation.session.fault == null) {
      _demand ??= context.acquireFrameDemand();
    } else {
      _demand?.dispose();
      _demand = null;
    }
    context.invalidate();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (realtime &&
        _clock == null &&
        !simulation.session.isClosed &&
        simulation.session.fault == null) {
      try {
        simulation.advance(
          frame.delta.inMicroseconds / Duration.microsecondsPerSecond,
        );
      } finally {
        _syncDemand();
      }
    }
  }

  @override
  void detach(PluginContext context) {
    _activity?.dispose();
    _activity = null;
    _clock?.dispose();
    _clock = null;
    _state?.cancel();
    _state = null;
    _demand?.dispose();
    _demand = null;
    _context = null;
    if (identical(_presentationOwners[simulation], this)) {
      _presentationOwners[simulation] = null;
    }
  }
}
