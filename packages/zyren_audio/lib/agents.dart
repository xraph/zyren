import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_audio.dart';

Map<String, Object?> _input(
  Map<String, Object?> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
const _id = {'type': 'string', 'minLength': 1, 'maxLength': 256};
const _output = {'type': 'object'};

/// Uses only the host's existing engine and emitter IDs. No file/network loading.
final class AudioAgentProvider extends AgentProvider {
  final SpatialAudio audio;
  final String sceneId, documentId;
  @override
  final String instanceId;
  AudioAgentProvider({
    required this.audio,
    required this.sceneId,
    required this.documentId,
    required this.instanceId,
  });
  AgentObjectMetadata? metadata(Object3D object) {
    if (audio.isClosed || !_attached(object)) return null;
    final matches = audio.emitters.where((emitter) => identical(emitter.node, object));
    if (matches.isEmpty) return null;
    return AgentObjectMetadata(sourceId: matches.first.id, owningPlugin: id,
      properties: {'emitterIds': matches.map((emitter) => emitter.id).toList()},
      provenance: {'binding': 'host-provided audio emitter ID'},
      actions: ['$id/$instanceId/inspect', '$id/$instanceId/play', '$id/$instanceId/pause']);
  }
  @override
  String get id => 'zyren_audio';
  @override
  String get version => '0.1.0';
  @override
  int get revision => audio.revision + audio.root.revision;
  @override
  Map<String, Object?> get capabilities => {
    'sceneId': sceneId,
    'documentId': documentId,
    'backend': audio.backend,
    'offline': audio.offline,
    'sampleRate': audio.sampleRate,
    'distanceUnits': 'scene units',
    'maxEmitters': audio.maxEmitters,
    'maxPcmBytes': audio.maxPcmBytes,
    'occlusion': 'unsupported',
    'undo':
        'playback is transport state; configure through host commands if persistent',
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Inspect the actual native listener, budgets and a page of emitter states.',
      inputSchema: _input({
        'offset': {'type': 'integer', 'minimum': 0},
        'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
      }),
      outputSchema: _output,
    ),
    for (final name in ['play', 'pause'])
      AgentTool(
        name: name,
        description: name == 'play'
            ? 'Resume an attached native emitter.'
            : 'Pause an attached native emitter.',
        inputSchema: _input({'emitterId': _id}, ['emitterId']),
        outputSchema: _output,
        readOnly: false,
        requiredScopes: {'audio.write'},
      ),
    AgentTool(
      name: 'configure',
      description:
          'Set volume and distance attenuation on an existing emitter.',
      inputSchema: _input(
        {
          'emitterId': _id,
          'volume': {'type': 'number', 'minimum': 0, 'maximum': 1},
          'minDistance': {
            'type': 'number',
            'minimum': .000001,
            'maximum': 1e12,
          },
          'maxDistance': {
            'type': 'number',
            'minimum': .000002,
            'maximum': 1e12,
          },
          'rolloff': {'type': 'number', 'minimum': 0, 'maximum': 100},
          'attenuation': {
            'type': 'string',
            'enum': ['none', 'inverse', 'linear', 'exponential'],
          },
          'loop': {'type': 'boolean'},
        },
        ['emitterId'],
      ),
      outputSchema: _output,
      readOnly: false,
      requiredScopes: {'audio.write'},
    ),
  ];
  bool _attached(Object3D node) {
    for (Object3D? p = node; p != null; p = p.parent) {
      if (identical(p, audio.root)) return true;
    }
    return false;
  }

  Map<String, Object?> _emitter(AudioEmitter e) {
    final m = e.node.worldMatrix.storage, s = e.settings;
    return {
      'id': e.id,
      'runtimeId': e.node.id,
      'position': [m[12], m[13], m[14]],
      'attached': _attached(e.node),
      'playing': e.isPlaying,
      'volume': s.volume,
      'loop': s.loop,
      'attenuation': s.attenuation.name,
      'minDistance': s.minDistance,
      'maxDistance': s.maxDistance,
      'rolloff': s.rolloff,
      'actions': ['play', 'pause', 'configure'],
    };
  }

  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (audio.isClosed) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Audio engine has closed.',
      );
    }
    if (!_attached(audio.listener.node)) {
      return AgentResult(AgentStatus.stale, message: 'Listener was removed.');
    }
    if (tool == 'inspect') {
      final offset = arguments['offset'] as int? ?? 0,
          limit = arguments['limit'] as int? ?? 16;
      final all = audio.emitters,
          page = all.skip(offset).take(limit).toList(),
          pose = audio.listener.pose;
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {
          'sceneId': sceneId,
          'documentId': documentId,
          'sceneRevision': audio.root.revision,
          'backend': audio.backend,
          'offline': audio.offline,
          'residentPcmBytes': audio.residentPcmBytes,
          'listener': {
            'runtimeId': audio.listener.node.id,
            'position': pose.position.storage,
            'forward': pose.forward.storage,
            'up': pose.up.storage,
          },
          'emitters': page.map(_emitter).toList(),
          'nextOffset': offset + page.length < all.length
              ? offset + page.length
              : null,
        },
      );
    }
    final matches = audio.emitters.where((e) => e.id == arguments['emitterId']);
    if (matches.isEmpty || !_attached(matches.first.node)) {
      return AgentResult(
        AgentStatus.stale,
        message: 'Emitter is no longer attached.',
      );
    }
    final emitter = matches.first;
    try {
      switch (tool) {
        case 'play':
          emitter.play();
        case 'pause':
          emitter.pause();
        case 'configure':
          final s = emitter.settings;
          emitter.configure(
            EmitterSettings(
              volume: (arguments['volume'] as num?)?.toDouble() ?? s.volume,
              minDistance:
                  (arguments['minDistance'] as num?)?.toDouble() ??
                  s.minDistance,
              maxDistance:
                  (arguments['maxDistance'] as num?)?.toDouble() ??
                  s.maxDistance,
              rolloff: (arguments['rolloff'] as num?)?.toDouble() ?? s.rolloff,
              loop: arguments['loop'] as bool? ?? s.loop,
              attenuation: arguments['attenuation'] == null
                  ? s.attenuation
                  : DistanceAttenuation.values.byName(
                      arguments['attenuation'] as String,
                    ),
            ),
          );
        default:
          return AgentResult(AgentStatus.unsupported);
      }
    } on ArgumentError {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Invalid emitter settings.',
      );
    }
    return AgentResult(
      AgentStatus.ok,
      revision: revision,
      affectedIds: [emitter.id],
      data: {'emitter': _emitter(emitter)},
    );
  }
}
