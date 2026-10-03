import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_effects/zyren_effects.dart';

/// Optional retrofit for existing effects. Reads the chain and controls the
/// scene color pipeline. Chain edits use the existing resource owner.
final class EffectsAgentProvider extends AgentProvider {
  final Scene scene;
  final ScreenEffectsController? effects;
  final String sceneId, documentId;
  @override
  final String instanceId;
  RenderSettings? _undo;
  ScreenEffectsSettings? _undoChain;
  int _edits = 0;
  ScreenEffectsSettings? _observedChain;
  bool _editing = false;
  int? _undoRevision;
  EffectsAgentProvider({
    required this.scene,
    required this.sceneId,
    required this.documentId,
    required this.instanceId,
    this.effects,
  }) : _observedChain = effects?.settings;
  @override
  String get id => 'zyren_effects';
  @override
  String get version => '0.1.0';
  @override
  int get revision {
    if (!identical(_observedChain, effects?.settings)) {
      _observedChain = effects?.settings;
      _edits++;
    }
    return scene.revision + (effects?.generation ?? 0) + _edits;
  }

  @override
  Map<String, Object?> get capabilities => {
    'sceneId': sceneId,
    'documentId': documentId,
    'controls': ['exposure', 'toneMapping', 'hdr', 'undo'],
    'chainControls': effects == null
        ? 'unavailable'
        : 'SMAA, dithering, lens, grading intensity/interpolation',
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
      name: 'chain',
      description:
          'Rebuild the attached native effects chain. Omitted properties preserve current settings and the host LUT.',
      inputSchema: {
        'type': 'object',
        'additionalProperties': false,
        'properties': {
          'dithering': {'type': 'boolean'},
          'smaa': {
            'type': 'string',
            'enum': ['off', ...SmaaPreset.values.map((p) => p.name)],
          },
          'gradingIntensity': {'type': 'number', 'minimum': 0, 'maximum': 1},
          'interpolation': {
            'type': 'string',
            'enum': HaldInterpolation.values.map((p) => p.name).toList(),
          },
          'lens': {'type': 'boolean'},
          'lensIntensity': {'type': 'number', 'minimum': 0, 'maximum': 16},
          'lensThreshold': {'type': 'number', 'minimum': 0, 'maximum': 65504},
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
              'lensIntensity': chain.lens?.intensity,
              'lensThreshold': chain.lens?.thresholdLevel,
              'interpolation': chain.interpolation.name,
            },
    };
  }

  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (tool == 'inspect') {
      return AgentResult(AgentStatus.ok, revision: revision, data: _state());
    }
    if (_editing) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'An effects rebuild is in progress.',
      );
    }
    if (effects?.isClosed == true) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Effects owner has closed.',
      );
    }
    final previous = scene.renderSettings, previousChain = effects?.settings;
    _editing = true;
    try {
      if (tool == 'configure') {
        scene.renderSettings = previous.copyWith(
          exposure: (arguments['exposure'] as num?)?.toDouble(),
          toneMapping: arguments['toneMapping'] == null
              ? null
              : ToneMapping.values.byName(arguments['toneMapping'] as String),
          hdr: arguments['hdr'] as bool?,
        );
      } else if (tool == 'chain') {
        final owner = effects, current = previousChain;
        if (owner == null || current == null) {
          return AgentResult(
            AgentStatus.unavailable,
            message: 'No effects controller is attached.',
          );
        }
        final oldLens = current.lens ?? LensFlareSettings();
        final lensEnabled = arguments['lens'] as bool? ?? current.lens != null;
        if (!lensEnabled &&
            (arguments.containsKey('lensIntensity') ||
                arguments.containsKey('lensThreshold'))) {
          return AgentResult(
            AgentStatus.invalid,
            message: 'Enable lens before setting lens parameters.',
          );
        }
        await owner.setSettings(
          ScreenEffectsSettings(
            dithering: arguments['dithering'] as bool? ?? current.dithering,
            smaa: arguments['smaa'] == null
                ? current.smaa
                : arguments['smaa'] == 'off'
                ? null
                : SmaaPreset.values.byName(arguments['smaa'] as String),
            grading: current.grading,
            gradingIntensity:
                (arguments['gradingIntensity'] as num?)?.toDouble() ??
                current.gradingIntensity,
            interpolation: arguments['interpolation'] == null
                ? current.interpolation
                : HaldInterpolation.values.byName(
                    arguments['interpolation'] as String,
                  ),
            lens: !lensEnabled
                ? null
                : LensFlareSettings(
                    resolutionScale: oldLens.resolutionScale,
                    maxResolution: oldLens.maxResolution,
                    intensity:
                        (arguments['lensIntensity'] as num?)?.toDouble() ??
                        oldLens.intensity,
                    thresholdLevel:
                        (arguments['lensThreshold'] as num?)?.toDouble() ??
                        oldLens.thresholdLevel,
                    thresholdRange: oldLens.thresholdRange,
                    ghostAmount: oldLens.ghostAmount,
                    haloAmount: oldLens.haloAmount,
                    chromaticAberration: oldLens.chromaticAberration,
                  ),
          ),
        );
      } else if (tool == 'undo') {
        if (_undoRevision != revision || _undo == null) {
          return AgentResult(
            AgentStatus.stale,
            message: 'Effect settings changed after the saved command.',
          );
        }
        if (_undoChain != null && !identical(_undoChain, previousChain)) {
          await effects!.setSettings(_undoChain!);
          if (!identical(scene.renderSettings, previous)) {
            _undoRevision = null;
            return AgentResult(
              AgentStatus.stale,
              revision: revision,
              message:
                  'Chain restored; concurrent scene color settings were preserved.',
              data: _state(),
            );
          }
        }
        scene.renderSettings = _undo!;
      } else {
        return AgentResult(AgentStatus.unsupported);
      }
      _edits++;
      _undo = previous;
      _undoChain = previousChain;
      _undoRevision =
          tool == 'chain' && !identical(scene.renderSettings, previous)
          ? null
          : revision;
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        affectedIds: [sceneId],
        data: _state(),
      );
    } on ArgumentError catch (error) {
      return AgentResult(AgentStatus.invalid, message: '$error');
    } on StateError catch (error) {
      return AgentResult(AgentStatus.failed, message: '$error');
    } finally {
      _editing = false;
    }
  }
}
