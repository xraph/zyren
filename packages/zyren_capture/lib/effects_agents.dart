import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_effects/zyren_effects.dart';

/// Optional retrofit for existing effects. Reads the chain and controls the
/// scene color pipeline without owning or replacing effect resources.
final class EffectsAgentProvider extends AgentProvider {
  final Scene scene;
  final ScreenEffectsController? effects;
  final String sceneId, documentId;
  @override
  final String instanceId;
  RenderSettings? _undo;
  int? _undoRevision;
  EffectsAgentProvider({
    required this.scene,
    required this.sceneId,
    required this.documentId,
    required this.instanceId,
    this.effects,
  });
  @override
  String get id => 'zyren_effects';
  @override
  String get version => '0.1.0';
  @override
  int get revision => scene.revision + (effects?.generation ?? 0);
  @override
  Map<String, Object?> get capabilities => {
    'sceneId': sceneId,
    'documentId': documentId,
    'controls': ['exposure', 'toneMapping', 'hdr', 'undo'],
    'chainControls': 'inspection only',
    'chainAttached': effects != null,
    'pixelResult': 'requires native rendering',
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Inspect real scene color settings and an optional attached effects chain.',
      inputSchema: const {'type': 'object', 'additionalProperties': false},
      outputSchema: const {'type': 'object'},
    ),
    AgentTool(
      name: 'configure',
      description:
          'Change exposure, tone mapping or HDR through scene render settings.',
      inputSchema: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'exposure': {'type': 'number', 'minimum': 0, 'maximum': 65504},
          'toneMapping': {
            'type': 'string',
            'enum': ToneMapping.values.map((v) => v.name).toList(),
          },
          'hdr': {'type': 'boolean'},
        },
      },
      outputSchema: const {'type': 'object'},
      readOnly: false,
      requiredScopes: {'effects.write'},
    ),
    AgentTool(
      name: 'undo',
      description:
          'Restore the preceding effect settings if the scene has not changed.',
      inputSchema: const {'type': 'object', 'additionalProperties': false},
      outputSchema: const {'type': 'object'},
      readOnly: false,
      requiredScopes: {'effects.write'},
    ),
  ];
  Map<String, Object?> _state() {
    final settings = scene.renderSettings, chain = effects?.settings;
    return {
      'sceneId': sceneId,
      'documentId': documentId,
      'sceneRevision': scene.revision,
      'exposure': settings.exposure,
      'toneMapping': settings.toneMapping.name,
      'hdr': settings.hdr,
      'effects': [
        for (final effect in scene.effects)
          {'stage': effect.stage.name, 'closed': effect.isClosed},
      ],
      'chain': chain == null
          ? null
          : {
              'closed': effects!.isClosed,
              'generation': effects!.generation,
              'dithering': chain.dithering,
              'smaa': chain.smaa?.name,
              'gradingIntensity': chain.gradingIntensity,
              'hasGradingLut': chain.grading != null,
              'hasLens': chain.lens != null,
            },
    };
  }

  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (tool == 'inspect') {
      return AgentResult(AgentStatus.ok, revision: revision, data: _state());
    }
    final previous = scene.renderSettings;
    if (tool == 'configure') {
      scene.renderSettings = previous.copyWith(
        exposure: (arguments['exposure'] as num?)?.toDouble(),
        toneMapping: arguments['toneMapping'] == null
            ? null
            : ToneMapping.values.byName(arguments['toneMapping'] as String),
        hdr: arguments['hdr'] as bool?,
      );
    } else if (tool == 'undo') {
      if (_undoRevision != revision || _undo == null) {
        return AgentResult(
          AgentStatus.stale,
          message: 'Effect settings changed after the saved command.',
        );
      }
      scene.renderSettings = _undo!;
    } else {
      return AgentResult(AgentStatus.unsupported);
    }
    _undo = previous;
    _undoRevision = revision;
    return AgentResult(
      AgentStatus.ok,
      revision: revision,
      affectedIds: [sceneId],
      data: _state(),
    );
  }
}
