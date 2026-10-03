/// Optional runtime adapter for the shared Zyren agent registry.
library;

export 'src/field_agents.dart';

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';

import 'src/scalar_slice.dart';
import 'src/slice_view.dart';
import 'src/transfer_function.dart';

/// Register for the view's lifetime. Disposing the returned registration only
/// removes agent access. Disposing the view also unregisters its provider.
Registration registerScientificView(
  AgentRegistry registry,
  ScientificSliceView view,
) {
  view.checkCurrent();
  final provider = ScientificAgentProvider(view);
  final registered = registry.register(provider);
  final lifecycle = view.onDispose(registered.dispose);
  return Registration(() {
    lifecycle.dispose();
    registered.dispose();
  });
}

final class ScientificAgentProvider extends AgentProvider {
  final ScientificSliceView view;
  ScientificAgentProvider(this.view);

  /// Pass this to the shared viewport provider's metadata callback, alongside
  /// other plugin callbacks. It exposes only this view's active mesh.
  AgentObjectMetadata? metadata(Object3D object) {
    if (view.isDisposed || !identical(object, view.mesh)) return null;
    view.checkCurrent();
    final grid = view.slice.grid;
    return AgentObjectMetadata(
      sourceId: grid.source.id,
      semanticType: 'scientific.scalar-slice',
      owningPlugin: id,
      properties: {
        'scientific': {
          'providerId': id,
          'instanceId': instanceId,
          'viewRevision': revision,
          'unit': unitJson(grid.valueUnit),
          'coordinateUnit': unitJson(grid.coordinateUnit),
          'axis': view.slice.axis.name,
          'index': view.slice.index,
          'missingPolicy': 'omit-any-affected-cell',
          'omittedCells': view.slice.omittedCells,
          'time': null,
          'timeStatus': 'unavailable-static-field',
          'valueQuery': 'sample_triangle',
          'interpolation': 'linear-plane-then-triangle-barycentric',
        },
      },
      provenance: {'sourceId': grid.source.id, 'kind': grid.source.kind.name},
      actions: ['set_slice', 'set_transfer'],
    );
  }

  @override
  String get id => 'zyren.scientific';
  @override
  String get version => '1.0';
  @override
  String get instanceId => view.id;
  @override
  int get revision => view.revision;
  @override
  Map<String, Object?> get capabilities => {
    'scalarSlices': true,
    'transferMapping': true,
    'timeVarying': false,
    'volumeRendering': false,
    'solver': false,
    'dataKind': view.slice.grid.source.kind.name,
    'mutationScope': 'scientific.edit',
    'undo': false,
    'maxSamples': view.budget.maxSamples,
    'maxSliceCells': view.budget.maxSliceCells,
    'maxGeometryBytes': view.budget.maxGeometryBytes,
    'screenContext': 'host-shared-viewport-provider',
  };
  @override
  List<Map<String, Object?>> get resources => [
    {
      'sourceId': view.slice.grid.source.id,
      'viewId': view.id,
      'kind': 'scalar-grid',
      'unit': unitJson(view.slice.grid.valueUnit),
    },
  ];

  static const _number = {'type': 'number'};
  static const _index = {'type': 'integer', 'minimum': 0};
  static Map<String, Object?> _input(
    Map<String, Object?> properties,
    List<String> required,
  ) => {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
  static const _state = {
    'type': 'object',
    'required': ['viewId', 'viewRevision', 'dataset', 'slice', 'transfer'],
    'properties': {
      'viewId': {'type': 'string'},
      'viewRevision': {'type': 'integer'},
      'dataset': {'type': 'object'},
      'slice': {'type': 'object'},
      'transfer': {'type': 'object'},
    },
  };
  static const _sample = {
    'type': 'object',
    'required': [
      'datasetId',
      'unit',
      'missing',
      'coordinates',
      'interpolation',
    ],
    'properties': {
      'datasetId': {'type': 'string'},
      'unit': {'type': 'object'},
      'missing': {'type': 'boolean'},
      'value': _number,
      'coordinates': {
        'type': 'array',
        'items': _index,
        'minItems': 2,
        'maxItems': 3,
      },
      'interpolation': {'type': 'string'},
      'time': {'type': 'null'},
    },
  };

  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Inspect scalar source, units, missing counts, slice, transfer and static time status.',
      inputSchema: _input({}, []),
      outputSchema: _state,
    ),
    AgentTool(
      name: 'sample',
      description:
          'Read a slice lattice sample at integer u,v; missing values have no numeric value.',
      inputSchema: _input({'u': _index, 'v': _index}, ['u', 'v']),
      outputSchema: _sample,
      examples: [
        {'u': 0, 'v': 0},
      ],
    ),
    AgentTool(
      name: 'field_sample',
      description:
          'Read a source grid sample at integer x,y,z with source identity and units.',
      inputSchema: _input(
        {'x': _index, 'y': _index, 'z': _index},
        ['x', 'y', 'z'],
      ),
      outputSchema: _sample,
    ),
    AgentTool(
      name: 'sample_triangle',
      description:
          'Join triangleIndex and barycentric weights from a shared viewport pick to a scalar value. Requires the picked runtime object and scene revision; does not assert pixel visibility.',
      inputSchema: _input(
        {
          'triangleIndex': _index,
          'runtimeObjectId': _index,
          'sceneRevision': _index,
          'barycentric': {
            'type': 'array',
            'minItems': 3,
            'maxItems': 3,
            'items': {'type': 'number', 'minimum': 0, 'maximum': 1},
          },
        },
        ['triangleIndex', 'runtimeObjectId', 'sceneRevision', 'barycentric'],
      ),
      outputSchema: {
        'type': 'object',
        'required': [
          'datasetId',
          'value',
          'unit',
          'viewRevision',
          'sceneRevision',
        ],
        'properties': {
          'datasetId': {'type': 'string'},
          'value': _number,
          'unit': {'type': 'object'},
          'viewRevision': _index,
          'sceneRevision': _index,
        },
      },
    ),
    AgentTool(
      name: 'set_slice',
      description:
          'Replace the active slice with an axis and fractional grid index. Requires scientific.edit, expected revision and retry key.',
      inputSchema: _input(
        {
          'axis': {
            'type': 'string',
            'enum': ['x', 'y', 'z'],
          },
          'index': _number,
        },
        ['axis', 'index'],
      ),
      outputSchema: _state,
      readOnly: false,
      requiredScopes: {'scientific.edit'},
      examples: [
        {'axis': 'z', 'index': .5},
      ],
    ),
    AgentTool(
      name: 'set_transfer',
      description:
          'Replace the scalar range in the existing field unit, optionally replacing linear RGB stops. Requires scientific.edit.',
      inputSchema: _input(
        {
          'minimum': _number,
          'maximum': _number,
          'stops': {
            'type': 'array',
            'minItems': 2,
            'maxItems': 256,
            'items': _input(
              {
                'position': {'type': 'number', 'minimum': 0, 'maximum': 1},
                'rgb': {
                  'type': 'array',
                  'minItems': 3,
                  'maxItems': 3,
                  'items': {'type': 'number', 'minimum': 0, 'maximum': 1},
                },
              },
              ['position', 'rgb'],
            ),
          },
        },
        ['minimum', 'maximum'],
      ),
      outputSchema: _state,
      readOnly: false,
      requiredScopes: {'scientific.edit'},
    ),
  ];

  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    try {
      context.checkCancelled();
      view.checkCurrent(expectedRevision: context.expectedRevision);
      switch (tool) {
        case 'sample_triangle':
          final weights = arguments['barycentric'] as List;
          return AgentResult(
            AgentStatus.ok,
            revision: revision,
            data: view.sampleTriangle(
              triangleIndex: arguments['triangleIndex'] as int,
              barycentric: Vec3(
                (weights[0] as num).toDouble(),
                (weights[1] as num).toDouble(),
                (weights[2] as num).toDouble(),
              ),
              runtimeObjectId: arguments['runtimeObjectId'] as int,
              expectedSceneRevision: arguments['sceneRevision'] as int,
              expectedRevision: context.expectedRevision ?? revision,
            ),
          );
        case 'inspect':
          return _stateResult();
        case 'sample':
        case 'field_sample':
          final grid = view.slice.grid;
          final coordinates = tool == 'sample'
              ? [arguments['u'] as int, arguments['v'] as int]
              : [
                  arguments['x'] as int,
                  arguments['y'] as int,
                  arguments['z'] as int,
                ];
          final value = tool == 'sample'
              ? view.slice.valueAt(coordinates[0], coordinates[1])
              : grid.valueAt(coordinates[0], coordinates[1], coordinates[2]);
          return AgentResult(
            value == null ? AgentStatus.empty : AgentStatus.ok,
            revision: revision,
            data: {
              'datasetId': grid.source.id,
              'sourceKind': grid.source.kind.name,
              'unit': unitJson(grid.valueUnit),
              'missing': value == null,
              'value': ?value,
              'coordinates': coordinates,
              'time': null,
              'interpolation': tool == 'sample'
                  ? 'linear-between-grid-planes'
                  : 'source-sample',
            },
          );
        case 'set_slice':
          context.checkCancelled();
          view.setSlice(
            axis: SliceAxis.values.byName(arguments['axis'] as String),
            index: (arguments['index'] as num).toDouble(),
            expectedRevision: context.expectedRevision!,
          );
          return _stateResult(mutated: true);
        case 'set_transfer':
          final stops = arguments['stops'] as List?;
          final transfer = ScalarTransferFunction(
            unit: view.slice.grid.valueUnit,
            minimum: (arguments['minimum'] as num).toDouble(),
            maximum: (arguments['maximum'] as num).toDouble(),
            stops: stops == null
                ? view.slice.transfer.stops
                : [
                    for (final raw in stops)
                      TransferStop(
                        (raw['position'] as num).toDouble(),
                        Color3(
                          (raw['rgb'][0] as num).toDouble(),
                          (raw['rgb'][1] as num).toDouble(),
                          (raw['rgb'][2] as num).toDouble(),
                        ),
                      ),
                  ],
          );
          context.checkCancelled();
          view.setTransfer(
            transfer,
            expectedRevision: context.expectedRevision!,
          );
          return _stateResult(mutated: true);
        default:
          return AgentResult(
            AgentStatus.unsupported,
            message: 'Scientific tool is unsupported.',
          );
      }
    } on ScientificViewException catch (error) {
      return AgentResult(
        error.reason == ScientificViewFailure.stale
            ? AgentStatus.stale
            : AgentStatus.unavailable,
        message: error.message,
      );
    } on ArgumentError {
      return AgentResult(
        AgentStatus.invalid,
        message:
            'Scientific input violates field, unit, precision or resource limits.',
      );
    }
  }

  AgentResult _stateResult({bool mutated = false}) => AgentResult(
    view.slice.isEmpty ? AgentStatus.empty : AgentStatus.ok,
    data: view.describe(),
    revision: revision,
    affectedIds: mutated ? [view.id] : const [],
  );
}
