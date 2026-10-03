/// Optional agent adapter over interaction and the ordinary scene tools API.
library;

import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_tools/zyren_tools.dart';
import 'zyren_interaction.dart';

/// Shares selection with tools and the inspector's selectedObject contract.
/// Attach tools before registering this provider; unregister before detaching.
final class InteractionAgentProvider extends AgentProvider {
  final SceneInteractionRouter router;
  final SceneToolsPlugin sceneTools;
  @override
  final String instanceId;
  final int maxNodes;
  String? _lastState;
  int _revision = 0;
  InteractionAgentProvider({
    required this.router,
    required this.sceneTools,
    required this.instanceId,
    this.maxNodes = 10000,
  });
  @override
  String get id => 'zyren.interaction';
  @override
  String get version => '0.1.0';
  @override
  int get revision {
    final state = jsonEncode([
      router.scene.revision,
      router.isDisposed,
      router.focus.focusedObject?.id,
      sceneTools.selected?.id,
      sceneTools.canUndo,
      sceneTools.canRedo,
      router.registeredObjects.map((object) => object.id).toList(),
      router.hoveredObjects.entries
          .map((entry) => [entry.key, entry.value.id])
          .toList(),
      router.capturedObjects.entries
          .map((entry) => [entry.key, entry.value.id])
          .toList(),
    ]);
    if (state != _lastState) {
      _lastState = state;
      _revision++;
    }
    return _revision;
  }

  @override
  Map<String, Object?> get capabilities => {
    'selection': true,
    'transformHistory': true,
    'captureScope': 'interaction-router-only',
    'cameraArbitration': true,
    'keyboardFocus': true,
  };
  static const empty = <String, Object?>{
    'type': 'object',
    'properties': {},
    'additionalProperties': false,
  };
  static const output = <String, Object?>{'type': 'object'};
  static const target = <String, Object?>{
    'runtimeId': {'type': 'integer', 'minimum': 1},
  };
  AgentTool _action(
    String name,
    String description,
    String scope,
    Map<String, Object?> properties,
  ) => AgentTool(
    name: name,
    description: description,
    readOnly: false,
    requiredScopes: {scope},
    inputSchema: {
      'type': 'object',
      'properties': properties,
      'required': properties.keys.toList(),
      'additionalProperties': false,
    },
    outputSchema: output,
  );
  @override
  late final List<AgentTool> tools = List.unmodifiable([
    AgentTool(
      name: 'state',
      description:
          'Read selection, hover, capture and transform history availability.',
      inputSchema: empty,
      outputSchema: output,
    ),
    _action(
      'select',
      'Select an attached object through scene tools.',
      'tools.select',
      target,
    ),
    _action(
      'clear_selection',
      'Clear selection through scene tools.',
      'tools.select',
      {},
    ),
    _action(
      'translate',
      'Set an object local position as one undoable tool command.',
      'tools.transform',
      {
        ...target,
        'x': {'type': 'number'},
        'y': {'type': 'number'},
        'z': {'type': 'number'},
      },
    ),
    _action(
      'undo',
      'Undo the last owned transform command.',
      'tools.transform',
      {},
    ),
    _action(
      'redo',
      'Redo the last owned transform command.',
      'tools.transform',
      {},
    ),
  ]);
  Map<String, Object?> _state() => {
    'selectedRuntimeId': sceneTools.selected?.id,
    'focusedRuntimeId': router.focus.focusedObject?.id,
    'canUndo': sceneTools.canUndo,
    'canRedo': sceneTools.canRedo,
    'registeredCount': router.registeredObjects.length,
    'hover': [
      for (final entry in router.hoveredObjects.entries.take(64))
        {'pointer': entry.key, 'runtimeId': entry.value.id},
    ],
    'capture': [
      for (final entry in router.capturedObjects.entries.take(64))
        {'pointer': entry.key, 'runtimeId': entry.value.id},
    ],
    'truncated':
        router.hoveredObjects.length > 64 || router.capturedObjects.length > 64,
    'sceneRevision': router.scene.revision,
  };
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (router.isDisposed) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Interaction was disposed.',
      );
    }
    if (context.expectedRevision != null &&
        context.expectedRevision != revision) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Interaction state changed.',
      );
    }
    Object3D? object;
    if (arguments['runtimeId'] case final int id) {
      final stack = <Object3D>[router.scene];
      var visited = 0;
      while (stack.isNotEmpty) {
        if (++visited > maxNodes) {
          return AgentResult(
            AgentStatus.unavailable,
            message: 'Scene lookup budget exceeded.',
          );
        }
        final next = stack.removeLast();
        if (next.id == id) {
          object = next;
          break;
        }
        stack.addAll(next.children);
      }
      if (object == null || identical(object, router.scene)) {
        return AgentResult(
          AgentStatus.stale,
          message: 'Object is no longer attached.',
        );
      }
    }
    final before = switch (tool) {
      'undo' => sceneTools.undoTarget,
      'redo' => sceneTools.redoTarget,
      _ => sceneTools.selected,
    };
    switch (tool) {
      case 'state':
        break;
      case 'select':
        sceneTools.select(object!);
      case 'clear_selection':
        sceneTools.select(null);
      case 'translate':
        sceneTools.transform(
          object!,
          position: Vec3(
            (arguments['x'] as num).toDouble(),
            (arguments['y'] as num).toDouble(),
            (arguments['z'] as num).toDouble(),
          ),
        );
      case 'undo':
        if (!sceneTools.undo()) {
          return AgentResult(
            AgentStatus.empty,
            data: _state(),
            revision: revision,
          );
        }
      case 'redo':
        if (!sceneTools.redo()) {
          return AgentResult(
            AgentStatus.empty,
            data: _state(),
            revision: revision,
          );
        }
      default:
        return AgentResult(AgentStatus.unsupported);
    }
    return AgentResult(
      AgentStatus.ok,
      data: _state(),
      revision: revision,
      affectedIds: tool == 'state'
          ? []
          : [
              if (object != null) '${object.id}',
              if (before != null && !identical(object, before)) '${before.id}',
            ],
    );
  }
}
