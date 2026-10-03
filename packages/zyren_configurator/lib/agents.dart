import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_configurator.dart';
import 'viewpoints.dart';

Map<String, Object?> _object(
  Map<String, Object?> properties, [
  List<String> required = const [],
]) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};
const _string = {'type': 'string', 'minLength': 1, 'maxLength': 256};
const _output = {'type': 'object'};

/// Register through the host AgentRegistry; dispose its registration on detach.
final class ConfiguratorAgentProvider extends AgentProvider {
  final SceneConfigurator controller;
  final Scene scene;
  final ConfigurationViewpoints? viewpoints;
  final PerspectiveCamera? camera;
  final ViewportMetrics Function()? viewport;
  final String sceneId, documentId;
  @override
  final String instanceId;
  SavedConfiguration? _undo;
  int? _undoRevision;
  ConfiguratorAgentProvider({
    required this.controller,
    required this.scene,
    required this.sceneId,
    required this.documentId,
    required this.instanceId,
    this.viewpoints,
    this.camera,
    this.viewport,
  });
  AgentObjectMetadata? metadata(Object3D object) {
    final matches = controller.targets.entries.where(
      (entry) => identical(entry.value, object),
    );
    if (matches.isEmpty || !_attached(object) || controller.isClosed) {
      return null;
    }
    return AgentObjectMetadata(
      sourceId: matches.first.key,
      owningPlugin: id,
      properties: {
        'catalogId': controller.catalog.id,
        'catalogRevision': controller.catalog.revision,
      },
      provenance: {'binding': 'host-provided stable catalog target'},
      actions: ['$id/$instanceId/inspect', '$id/$instanceId/apply'],
    );
  }

  @override
  String get id => 'zyren_configurator';
  @override
  String get version => '0.1.0';
  @override
  int get revision =>
      (controller.revision + scene.revision) + (camera?.revision ?? 0);
  @override
  Map<String, Object?> get capabilities => {
    'sceneId': sceneId,
    'documentId': documentId,
    'stableTargetIds': true,
    'viewpoints': viewpoints != null && camera != null && viewport != null,
    'undo': 'last provider selection, if unchanged',
    'pixelVisibility': 'unknown',
  };
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Inspect catalog slots, saved selection and target identities.',
      inputSchema: _object({}),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'options',
      description:
          'Page actual options with material/component writes and compatibility rules.',
      inputSchema: _object(
        {
          'slot': _string,
          'offset': {'type': 'integer', 'minimum': 0},
          'limit': {'type': 'integer', 'minimum': 1, 'maximum': 32},
        },
        ['slot'],
      ),
      outputSchema: _output,
    ),
    AgentTool(
      name: 'apply',
      description:
          'Validate and apply a complete configuration through the controller.',
      inputSchema: _object(
        {
          'choices': {
            'type': 'array',
            'maxItems': 128,
            'items': _object(
              {'slot': _string, 'option': _string},
              ['slot', 'option'],
            ),
          },
        },
        ['choices'],
      ),
      outputSchema: _output,
      readOnly: false,
      requiredScopes: {'configurator.write'},
      examples: [
        {
          'choices': [
            {'slot': 'finish', 'option': 'red'},
          ],
        },
      ],
    ),
    if (viewpoints != null && camera != null && viewport != null) ...[
      AgentTool(
        name: 'viewpoints',
        description:
            'List camera presets and project source-bound hotspots in the active viewport.',
        inputSchema: _object({}),
        outputSchema: _output,
      ),
      AgentTool(
        name: 'camera',
        description:
            'Apply a validated camera preset to the active perspective camera.',
        inputSchema: _object({'id': _string}, ['id']),
        outputSchema: _output,
        readOnly: false,
        requiredScopes: {'configurator.camera'},
      ),
    ],
    for (final action in ['reset', 'undo'])
      AgentTool(
        name: action,
        description: action == 'reset'
            ? 'Restore original scene materials and visibility.'
            : 'Restore the preceding provider selection if state is unchanged.',
        inputSchema: _object({}),
        outputSchema: _output,
        readOnly: false,
        requiredScopes: {'configurator.write'},
      ),
  ];
  bool _attached(Object3D node) {
    for (Object3D? current = node; current != null; current = current.parent) {
      if (identical(current, scene)) return true;
    }
    return false;
  }

  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (controller.isClosed) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Configurator has closed.',
      );
    }
    if (controller.targets.values.any((node) => !_attached(node))) {
      return AgentResult(
        AgentStatus.stale,
        message: 'A configuration target was removed.',
      );
    }
    if (tool == 'viewpoints' || tool == 'camera') {
      final views = viewpoints, activeCamera = camera, metrics = viewport;
      if (views == null || activeCamera == null || metrics == null) {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'No active camera/viewport bindings.',
        );
      }
      if (views.targets.values.any((node) => !_attached(node))) {
        return AgentResult(
          AgentStatus.stale,
          message: 'A hotspot target was removed.',
        );
      }
      if (tool == 'camera') {
        final preset = views.presets[arguments['id']];
        if (preset == null) {
          return AgentResult(
            AgentStatus.stale,
            message: 'Unknown camera preset.',
          );
        }
        preset.apply(activeCamera);
        return AgentResult(
          AgentStatus.ok,
          revision: revision,
          affectedIds: [preset.id],
        );
      }
      if (!metrics().isUsable) {
        return AgentResult(
          AgentStatus.unavailable,
          message: 'Viewport is not mounted.',
        );
      }
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {
          'presets': views.presets.keys.toList(),
          'hotspots': views.project(activeCamera, metrics()),
        },
      );
    }
    final catalog = controller.catalog;
    if (tool == 'inspect') {
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {
          'sceneId': sceneId,
          'documentId': documentId,
          'sceneRevision': scene.revision,
          'catalogId': catalog.id,
          'catalogRevision': catalog.revision,
          'selection': controller.current?.encode(),
          'slots': [
            for (final slot in catalog.slots.values)
              {
                'id': slot.id,
                'required': slot.required,
                'optionCount': slot.options.length,
              },
          ],
          'targets': [
            for (final entry in controller.targets.entries)
              {'sourceId': entry.key, 'runtimeId': entry.value.id},
          ],
          'actions': ['apply', 'reset', 'undo'],
        },
      );
    }
    if (tool == 'options') {
      final slot = catalog.slots[arguments['slot']];
      if (slot == null) {
        return AgentResult(AgentStatus.stale, message: 'Unknown catalog slot.');
      }
      final offset = arguments['offset'] as int? ?? 0,
          limit = arguments['limit'] as int? ?? 16;
      final page = slot.options.values.skip(offset).take(limit).toList();
      return AgentResult(
        page.isEmpty ? AgentStatus.empty : AgentStatus.ok,
        revision: revision,
        data: {
          'slot': slot.id,
          'options': [
            for (final option in page)
              {
                'id': option.id,
                'materials': option.materials,
                'visibility': option.visibility,
                'requires': option.requires,
                'excludes': option.excludes,
              },
          ],
          'nextOffset': offset + page.length < slot.options.length
              ? offset + page.length
              : null,
        },
      );
    }
    final previous = controller.current;
    try {
      switch (tool) {
        case 'apply':
          final items = arguments['choices'] as List;
          final choices = {
            for (final item in items)
              (item as Map)['slot'] as String: item['option'] as String,
          };
          if (choices.length != items.length) {
            return AgentResult(
              AgentStatus.invalid,
              message: 'Duplicate choice slots.',
            );
          }
          controller.apply(catalog.select(choices));
        case 'reset':
          controller.reset();
        case 'undo':
          if (_undoRevision != revision) {
            return AgentResult(
              AgentStatus.stale,
              message: 'The saved undo state no longer matches.',
            );
          }
          if (_undo == null) {
            controller.reset();
          } else {
            controller.apply(_undo!);
          }
        default:
          return AgentResult(AgentStatus.unsupported);
      }
    } on ArgumentError {
      return AgentResult(
        AgentStatus.invalid,
        message: 'Choices violate catalog or binding rules.',
      );
    }
    _undo = previous;
    _undoRevision = revision;
    return AgentResult(
      AgentStatus.ok,
      revision: revision,
      affectedIds: controller.targets.keys.toList(),
      data: {
        'catalogId': catalog.id,
        'selection': controller.current?.encode(),
      },
    );
  }
}
