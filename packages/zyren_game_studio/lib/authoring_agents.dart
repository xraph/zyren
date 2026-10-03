import 'dart:async';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'authoring.dart';

/// Uses the same validated edits and history entry as the component inspector.
final class GameAuthoringAgent extends AgentProvider {
  final GameAuthoring authoring;
  final StudioScene scene;
  final bool Function() isAvailable;
  final FutureOr<void> Function(StudioDocument) applyDocument;
  @override
  final String instanceId;
  GameAuthoringAgent({
    required this.authoring,
    required this.scene,
    required this.isAvailable,
    required this.applyDocument,
    required this.instanceId,
  });
  @override
  String get id => 'zyren.game-authoring';
  @override
  String get version => '0.1.0';
  @override
  int get revision => scene.revision;
  @override
  Map<String, Object?> get capabilities => {
    'history': 'document',
    'prefabOverrides': true,
  };
  static const _text = {'type': 'string', 'minLength': 1, 'maxLength': 1024};
  static const _object = {'type': 'object'};
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'validate',
      description: 'Read up to 64 component issues from authored data.',
      inputSchema: const {
        'type': 'object',
        'additionalProperties': false,
        'properties': {},
      },
      outputSchema: _object,
    ),
    for (final action in [
      'add_component',
      'remove_component',
      'set_fields',
      'make_prefab',
      'duplicate',
    ])
      AgentTool(
        name: action,
        description: '$action through the shared Studio document history.',
        readOnly: false,
        requiredScopes: {'studio.edit'},
        inputSchema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'nodeId': _text,
            if (action.endsWith('component') || action == 'set_fields')
              'component': _text,
            if (action == 'set_fields') 'fields': _object,
            if (action == 'make_prefab' || action == 'duplicate')
              'newId': _text,
          },
          'required': [
            'nodeId',
            if (action.endsWith('component') || action == 'set_fields')
              'component',
            if (action == 'set_fields') 'fields',
            if (action == 'make_prefab' || action == 'duplicate') 'newId',
          ],
        },
        outputSchema: _object,
      ),
  ];
  @override
  Future<AgentResult> invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) async {
    context.checkCancelled();
    if (!isAvailable()) return AgentResult(AgentStatus.unavailable);
    if (tool == 'validate') {
      final issues = authoring.validate(scene.document);
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {
          'total': issues.length,
          'issues': [
            for (final i in issues.take(64))
              {
                'message': i.message,
                'nodeId': i.nodeId,
                'component': i.component,
                'field': i.field,
                'blocking': i.blocksPlay,
              },
          ],
        },
      );
    }
    if (context.expectedRevision != revision) {
      return AgentResult(AgentStatus.stale, revision: revision);
    }
    try {
      final document = scene.document, nodeId = arguments['nodeId'] as String;
      final component = arguments['component'] as String?;
      final next = switch (tool) {
        'add_component' => authoring.addComponent(
          document,
          nodeId,
          (authoring.descriptors[component] ??
                  (throw ArgumentError('Unknown component.')))
              .create(),
        ),
        'remove_component' => authoring.removeComponent(
          document,
          nodeId: nodeId,
          component: component!,
        ),
        'set_fields' => authoring.setFields(
          document,
          nodeId: nodeId,
          component: component!,
          fields: Map<String, Object?>.from(arguments['fields'] as Map),
        ),
        'make_prefab' => authoring.createPrefab(
          document,
          nodeId,
          prefabId: arguments['newId'] as String,
        ),
        'duplicate' => authoring.duplicate(
          document,
          nodeId,
          newId: arguments['newId'] as String,
        ),
        _ => throw UnsupportedError('Unknown game authoring command.'),
      };
      context.checkCancelled();
      await applyDocument(next);
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        data: {'changed': next.encode() != document.encode()},
      );
    } catch (error) {
      return AgentResult(
        AgentStatus.invalid,
        message: error.toString(),
        revision: revision,
      );
    }
  }
}
