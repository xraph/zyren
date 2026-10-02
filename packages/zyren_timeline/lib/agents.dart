/// Optional runtime tools for the existing timeline clock.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_timeline.dart';

final class TimelineAgentProvider extends AgentProvider {
  final SceneTimelinePlugin timeline;
  @override
  final String instanceId;
  final int Function() readRevision;
  final bool Function() isAvailable;
  final void Function(String name, void Function() apply)? runCommand;
  TimelineAgentProvider({
    required this.timeline,
    required this.instanceId,
    required this.readRevision,
    required this.isAvailable,
    this.runCommand,
  });
  @override
  String get id => 'zyren.timeline';
  @override
  String get version => '0.1.0';
  @override
  int get revision => readRevision();
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'timeUnits': 'seconds',
    'clock': 'main-timeline',
    'actionClocks': 'independent',
    'commandsAvailable': runCommand != null,
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description: 'Read the main timeline clock and bounded target IDs.',
      inputSchema: const {'type': 'object', 'additionalProperties': false},
      outputSchema: const {
        'type': 'object',
        'properties': {
          'positionSeconds': {'type': 'number'},
          'durationSeconds': {'type': 'number'},
          'playing': {'type': 'boolean'},
          'loop': {'type': 'boolean'},
          'reverse': {'type': 'boolean'},
          'runtimeTargetIds': {
            'type': 'array',
            'items': {'type': 'integer'},
            'maxItems': 128,
          },
          'targetsTruncated': {'type': 'boolean'},
        },
        'required': [
          'positionSeconds',
          'durationSeconds',
          'playing',
          'loop',
          'reverse',
          'runtimeTargetIds',
          'targetsTruncated',
        ],
        'additionalProperties': false,
      },
    ),
    AgentTool(
      name: 'playback',
      description:
          'Play, pause or seek the main clock through host commands. Action clocks are independent.',
      readOnly: false,
      requiredScopes: const {'timeline.playback'},
      inputSchema: const {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['play', 'pause', 'seek'],
          },
          'seconds': {'type': 'number', 'minimum': 0, 'maximum': 86400},
        },
        'required': ['action'],
        'additionalProperties': false,
      },
      outputSchema: const {
        'type': 'object',
        'properties': {
          'positionSeconds': {'type': 'number'},
          'playing': {'type': 'boolean'},
        },
        'required': ['positionSeconds', 'playing'],
        'additionalProperties': false,
      },
    ),
  ];
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (!isAvailable()) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Timeline target is unavailable.',
      );
    }
    if (tool == 'inspect') {
      return AgentResult(
        AgentStatus.ok,
        data: {
          'positionSeconds': timeline.position.inMicroseconds / 1e6,
          'durationSeconds': timeline.duration.inMicroseconds / 1e6,
          'playing': timeline.isPlaying,
          'loop': timeline.loop,
          'reverse': timeline.reverse,
          'runtimeTargetIds': timeline.tracks
              .take(128)
              .map((t) => t.target.id)
              .toList(),
          'targetsTruncated': timeline.tracks.length > 128,
        },
        revision: revision,
      );
    }
    if (tool != 'playback') return AgentResult(AgentStatus.unsupported);
    if (runCommand == null) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Host command gateway is unavailable.',
      );
    }
    final action = arguments['action'];
    if (action == 'seek' && arguments['seconds'] is! num) {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Seek requires seconds.',
      );
    }
    final before = revision;
    runCommand!('timeline.$action', () {
      context.checkCancelled();
      if (revision != before || !isAvailable()) {
        throw StateError('Timeline changed before command.');
      }
      switch (action) {
        case 'play':
          timeline.play();
        case 'pause':
          timeline.pause();
        case 'seek':
          timeline.seek(
            Duration(
              microseconds: ((arguments['seconds'] as num) * 1e6).round(),
            ),
          );
      }
    });
    return AgentResult(
      AgentStatus.ok,
      data: {
        'positionSeconds': timeline.position.inMicroseconds / 1e6,
        'playing': timeline.isPlaying,
      },
      revision: revision,
      affectedIds: [instanceId],
    );
  }
}
