/// Optional shared agent and Devtools integration for a host-owned session.
library;

import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'zyren_game.dart';

final class GameAgentProvider extends AgentProvider {
  final GameSession? Function() session;
  @override
  final String instanceId;
  final SceneDiagnostics? diagnostics;
  GameEventSubscription? _state;
  GameAgentProvider({
    required this.session,
    required this.instanceId,
    this.diagnostics,
  });
  @override
  String get id => 'zyren.game';
  @override
  String get version => '0.1.0';
  @override
  int get revision => session()?.revision ?? 0;
  @override
  Map<String, Object?> get capabilities => {
    'manualStep': true,
    'runtimeState': true,
    'pixels': 'unknown',
  };
  Registration attach(AgentRegistry registry) {
    final registration = registry.register(this);
    final current = session();
    _state = current?.listenState(() {
      diagnostics?.recordIssue(
        SceneIssue(
          code: 'game.state',
          message: jsonEncode(GameDiagnostics(session).snapshot()),
          operation: 'game-state',
          severity: current.fault != null
              ? IssueSeverity.error
              : IssueSeverity.info,
          pluginId: id,
        ),
      );
    });
    return Registration(() {
      _state?.cancel();
      _state = null;
      registration.dispose();
    });
  }

  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Read bounded game counters and distinguish running, paused, failed and missing sessions.',
      inputSchema: _empty,
      outputSchema: const {'type': 'object'},
    ),
    for (final command in ['pause', 'resume', 'step'])
      AgentTool(
        name: command,
        description: command == 'step'
            ? 'Advance one authoritative tick while paused.'
            : '$command the host game session.',
        inputSchema: _empty,
        outputSchema: const {'type': 'object'},
        readOnly: false,
        requiredScopes: {'game.control'},
      ),
  ];
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    final current = session();
    if (tool == 'inspect') {
      return AgentResult(
        AgentStatus.ok,
        data: GameDiagnostics(session).snapshot(),
        revision: revision,
      );
    }
    if (current == null || current.isClosed || current.fault != null) {
      return AgentResult(
        AgentStatus.unavailable,
        data: GameDiagnostics(session).snapshot(),
      );
    }
    switch (tool) {
      case 'pause':
        current.pause();
      case 'resume':
        current.resume();
      case 'step':
        if (!current.paused) {
          return AgentResult(
            AgentStatus.invalid,
            message: 'Pause the session before stepping.',
          );
        }
        current.resume();
        try {
          current.step();
        } finally {
          if (!current.isClosed && current.fault == null) current.pause();
        }
      default:
        return AgentResult(AgentStatus.unsupported);
    }
    return AgentResult(
      AgentStatus.ok,
      data: GameDiagnostics(session).snapshot(),
      revision: revision,
    );
  }
}

const _empty = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{},
  'additionalProperties': false,
};
