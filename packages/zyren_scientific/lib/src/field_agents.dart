import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'field_view.dart';
import 'slice_view.dart';
import 'transfer_function.dart';
import 'work.dart';

Registration registerScientificField(
  AgentRegistry registry,
  ScientificFieldView view,
) {
  final registration = registry.register(ScientificFieldAgentProvider(view));
  final lifetime = view.onDispose(registration.dispose);
  return Registration(() {
    lifetime.dispose();
    registration.dispose();
  });
}

/// Rich field state and the same atomic commands used by your native viewport.
final class ScientificFieldAgentProvider extends AgentProvider {
  final ScientificFieldView view;
  ScientificFieldAgentProvider(this.view);
  @override
  String get id => 'zyren.scientific.field';
  @override
  String get version => '1.0';
  @override
  String get instanceId => view.id;
  @override
  int get revision => view.revision;
  @override
  Map<String, Object?> get capabilities => {
    'undo': true,
    'redo': true,
    'history': 'bounded-session',
    'isosurfaces': true,
    'vectors': view.vectors != null,
    'streamlines': view.vectors != null,
    'temporal': view.temporal != null,
    'volume': view.volume != null,
    'solver': false,
    'mutationScope': 'scientific.edit',
    'maxSamples': 1000000,
    'maxGeometryBytes': 16777216,
    'volumePicking': 'source-sampling-only',
  };
  @override
  List<Map<String, Object?>> get resources => [
    {
      'sourceId': view.activeSource.id,
      'kind': 'scientific-field',
      'unit': unitJson(view.activeUnit),
    },
  ];
  AgentObjectMetadata? metadata(Object3D object) {
    if (view.isDisposed || object != view.mesh) return null;
    return AgentObjectMetadata(
      sourceId: view.activeSource.id,
      semanticType: 'scientific.${view.representation.name}',
      owningPlugin: id,
      properties: {
        'scientific': view.describe(),
        'scalarQuery':
            view.representation == ScientificRepresentation.slice ||
                view.representation == ScientificRepresentation.isosurface
            ? 'sample_triangle'
            : 'sample_position',
      },
      provenance: {
        'sourceId': view.activeSource.id,
        'kind': view.activeSource.kind.name,
      },
      actions: [
        'set_representation',
        'set_parameters',
        if (view.temporal != null) 'seek',
      ],
    );
  }

  static const _number = {'type': 'number'};
  static const _position = {
    'type': 'array',
    'minItems': 3,
    'maxItems': 3,
    'items': _number,
  };
  static const _output = {'type': 'object'};
  static Map<String, Object?> _input(
    Map<String, Object?> properties,
    List<String> required,
  ) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'history',
      description:
          'Read bounded undo/redo entries and retained payload limits.',
      inputSchema: _input({}, []),
      outputSchema: {'type': 'object'},
    ),
    for (final name in ['undo', 'redo', 'clear_history'])
      AgentTool(
        name: name,
        description: name == 'clear_history'
            ? 'Release retained history without changing the scientific view.'
            : 'Restore the ${name == 'undo' ? 'previous' : 'next'} scientific state through the same validated scene swap.',
        inputSchema: _input({}, []),
        outputSchema: {'type': 'object'},
        readOnly: false,
        requiredScopes: {'scientific.edit'},
      ),
    AgentTool(
      name: 'inspect',
      description:
          'Read current representation, source, units, frame versions, missing counts, numerical error and limits.',
      inputSchema: _input({}, []),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'sample_position',
      description:
          'Sample scalar and available vector components at a grid-local point. Reports missing/outside and static vector time separately; does not establish pixel visibility.',
      inputSchema: _input({'position': _position}, ['position']),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'sample_triangle',
      description:
          'Join a shared viewport triangle pick to scalar source data and isosurface cell identity.',
      inputSchema: _input(
        {
          'runtimeObjectId': {'type': 'integer', 'minimum': 0},
          'sceneRevision': {'type': 'integer', 'minimum': 0},
          'triangleIndex': {'type': 'integer', 'minimum': 0},
          'barycentric': _position,
        },
        ['runtimeObjectId', 'sceneRevision', 'triangleIndex', 'barycentric'],
      ),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'set_representation',
      description:
          'Build and atomically display a slice, isosurface, vectors, streamline or native volume.',
      inputSchema: _input(
        {
          'representation': {
            'type': 'string',
            'enum': ScientificRepresentation.values.map((v) => v.name).toList(),
          },
        },
        ['representation'],
      ),
      outputSchema: _output,
      readOnly: false,
      requiredScopes: {'scientific.edit'},
    ),
    AgentTool(
      name: 'set_parameters',
      description:
          'Change threshold, slice index, streamline seed, glyph scale or volume opacity and sample distance in the current units.',
      inputSchema: _input({
        'threshold': _number,
        'sliceIndex': _number,
        'seed': _position,
        'vectorScale': {'type': 'number', 'exclusiveMinimum': 0},
        'volumeOpacity': {'type': 'number', 'minimum': 0, 'maximum': 1},
        'volumeSampleDistance': {'type': 'number', 'exclusiveMinimum': 0},
      }, []),
      outputSchema: _output,
      readOnly: false,
      requiredScopes: {'scientific.edit'},
    ),
    AgentTool(
      name: 'set_transfer',
      description:
          'Change scalar transfer limits while preserving the field unit and color stops.',
      inputSchema: _input(
        {'minimum': _number, 'maximum': _number},
        ['minimum', 'maximum'],
      ),
      outputSchema: _output,
      readOnly: false,
      requiredScopes: {'scientific.edit'},
    ),
    if (view.temporal != null)
      AgentTool(
        name: 'seek',
        description:
            'Seek versioned source frames using linear interpolation and a bounded two-frame cache.',
        inputSchema: _input({'time': _number}, ['time']),
        outputSchema: _output,
        readOnly: false,
        requiredScopes: {'scientific.edit'},
      ),
  ];
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    try {
      view.checkCurrent(expectedRevision: context.expectedRevision);
      context.checkCancelled();
      double? number(String key) => (arguments[key] as num?)?.toDouble();
      Vec3 position(String key) => Vec3.array(
        (arguments[key] as List).map((v) => (v as num).toDouble()).toList(),
      );
      final cancellation = ScientificCancellation(
        isCancellationRequested: () => context.cancellation.isCancelled,
      );
      switch (tool) {
        case 'history':
          return AgentResult(
            AgentStatus.ok,
            data: view.history,
            revision: revision,
          );
        case 'undo':
        case 'redo':
          final changed = tool == 'undo'
              ? await view.undo(
                  expectedRevision: context.expectedRevision!,
                  cancellation: cancellation,
                )
              : await view.redo(
                  expectedRevision: context.expectedRevision!,
                  cancellation: cancellation,
                );
          return AgentResult(
            changed ? AgentStatus.ok : AgentStatus.empty,
            data: view.describe(),
            revision: revision,
            affectedIds: changed ? [view.id] : [],
          );
        case 'clear_history':
          await view.clearHistory(
            expectedRevision: context.expectedRevision!,
            cancellation: cancellation,
          );
          return AgentResult(
            AgentStatus.ok,
            data: view.describe(),
            revision: revision,
            affectedIds: [view.id],
          );
        case 'inspect':
          break;
        case 'sample_position':
          return AgentResult(
            AgentStatus.ok,
            data: view.sample(position('position')),
            revision: revision,
          );
        case 'sample_triangle':
          return AgentResult(
            AgentStatus.ok,
            revision: revision,
            data: view.sampleTriangle(
              runtimeObjectId: arguments['runtimeObjectId'] as int,
              sceneRevision: arguments['sceneRevision'] as int,
              triangleIndex: arguments['triangleIndex'] as int,
              barycentric: position('barycentric'),
            ),
          );
        case 'set_representation':
          await view.configure(
            expectedRevision: context.expectedRevision!,
            representation: ScientificRepresentation.values.byName(
              arguments['representation'] as String,
            ),
            cancellation: cancellation,
          );
        case 'set_parameters':
          await view.configure(
            expectedRevision: context.expectedRevision!,
            threshold: number('threshold'),
            sliceIndex: number('sliceIndex'),
            seed: arguments.containsKey('seed') ? position('seed') : null,
            vectorScale: number('vectorScale'),
            volumeOpacity: number('volumeOpacity'),
            volumeSampleDistance: number('volumeSampleDistance'),
            cancellation: cancellation,
          );
        case 'set_transfer':
          await view.configure(
            expectedRevision: context.expectedRevision!,
            transfer: ScalarTransferFunction(
              unit: view.grid.valueUnit,
              minimum: number('minimum')!,
              maximum: number('maximum')!,
              stops: view.transfer.stops,
            ),
            cancellation: cancellation,
          );
        case 'seek':
          await view.configure(
            expectedRevision: context.expectedRevision!,
            time: number('time'),
            cancellation: cancellation,
          );
        default:
          return AgentResult(
            AgentStatus.unsupported,
            message: 'Unknown scientific field tool.',
          );
      }
      return AgentResult(
        AgentStatus.ok,
        data: view.describe(),
        revision: revision,
        affectedIds: tool == 'inspect' ? [] : [view.id],
      );
    } on ScientificCancelled {
      return AgentResult(
        AgentStatus.cancelled,
        message: 'Scientific work cancelled before commit.',
      );
    } on ScientificViewException catch (e) {
      return AgentResult(
        e.reason == ScientificViewFailure.stale
            ? AgentStatus.stale
            : AgentStatus.unavailable,
        message: e.message,
      );
    } on ArgumentError catch (e) {
      return AgentResult(AgentStatus.invalid, message: e.toString());
    } on StateError catch (e) {
      return AgentResult(AgentStatus.unavailable, message: e.toString());
    }
  }
}
