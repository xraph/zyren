import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_studio.dart';

/// Saved procedural authoring. All batches validate before touching live content.
class StudioModelingAgentProvider extends AgentProvider {
  final StudioScene scene;
  final bool Function() isAvailable;
  final void Function() onChanged;
  final int Function() hostRevision;
  @override
  final String instanceId;
  StudioModelingAgentProvider({
    required this.scene,
    required this.instanceId,
    required this.isAvailable,
    required this.onChanged,
    required this.hostRevision,
  });
  @override
  String get id => 'zyren.studio.modeling';
  @override
  String get version => '1.0.0';
  @override
  int get revision => scene.revision + hostRevision();
  @override
  Map<String, Object?> get capabilities => {
    'shapes': StudioNodeKind.values
        .where((k) => k.isPrimitive)
        .map((k) => k.name)
        .toList(),
    'history': 'document',
    'persistent': true,
    'characters': 'articulated-primitive-blockout',
    'skinning': false,
    'sculpting': false,
    'morphing': 'requires-plugin',
  };
  static const _text = {'type': 'string', 'minLength': 1, 'maxLength': 128};
  static Map<String, Object?> _vector({
    double minimum = -10000,
    int length = 3,
  }) => {
    'type': 'array',
    'minItems': length,
    'maxItems': length,
    'items': {'type': 'number', 'minimum': minimum, 'maximum': 10000},
  };
  static Map<String, Object?> get _nodeSchema => {
    'type': 'object',
    'additionalProperties': false,
    'required': ['id', 'kind'],
    'properties': {
      'id': _text,
      'label': _text,
      'parentId': _text,
      'kind': {
        'type': 'string',
        'enum': [
          'group',
          ...StudioNodeKind.values
              .where((k) => k.isPrimitive)
              .map((k) => k.name),
        ],
      },
      'position': _vector(),
      'size': _vector(minimum: .0001),
      'scale': _vector(minimum: .0001),
      'rotation': _vector(length: 4),
      'color': {'type': 'integer', 'minimum': 0, 'maximum': 16777215},
    },
  };
  AgentTool _command(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) => AgentTool(
    name: name,
    description: description,
    readOnly: false,
    requiredScopes: {'studio.edit'},
    inputSchema: {
      'type': 'object',
      'additionalProperties': false,
      'properties': properties,
      'required': required,
    },
    outputSchema: const {'type': 'object'},
  );
  @override
  List<AgentTool> get tools => [
    _command(
      'create_nodes',
      'Create 1 to 64 saved shapes or groups atomically. size is XYZ dimensions; sphere dimensions are diameters, cylinder/cone point along Y, torus lies in XY. rotation is XYZW quaternion. Parent IDs may refer to this batch. Use groups as joint pivots.',
      {
        'nodes': {
          'type': 'array',
          'minItems': 1,
          'maxItems': 64,
          'items': _nodeSchema,
        },
      },
      ['nodes'],
    ),
    _command(
      'resize_shape',
      'Change a saved primitive size through document history. Prefab children must be edited through their definition.',
      {'targetId': _text, 'size': _vector(minimum: .0001)},
      ['targetId', 'size'],
    ),
    _command(
      'create_character_blockout',
      'Build a saved articulated humanoid from primitives, with shoulder, elbow, hip, knee and neck pivots. Pose with studio.transform and animate with studio-authoring tools. This does not create a skinned mesh or production rig.',
      {
        'id': _text,
        'label': _text,
        'position': _vector(),
        'height': {'type': 'number', 'minimum': .1, 'maximum': 100},
        'color': {'type': 'integer', 'minimum': 0, 'maximum': 16777215},
      },
      ['id'],
    ),
  ];

  Vec3 _vec(Object? value, Vec3 fallback) => value == null
      ? fallback
      : Vec3.array((value as List).map((v) => (v as num).toDouble()).toList());
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (!isAvailable()) {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Editor is busy or viewport is not ready.',
      );
    }
    if (context.expectedRevision != revision) {
      return AgentResult(AgentStatus.stale);
    }
    try {
      final doc = scene.capture();
      final StudioDocument next;
      final ids = <String>[];
      switch (tool) {
        case 'create_nodes':
          final nodes = (arguments['nodes'] as List).map((raw) {
            final n = raw as Map;
            final r = (n['rotation'] as List?)
                ?.map((v) => (v as num).toDouble())
                .toList();
            return StudioNode(
              id: n['id'] as String,
              label: n['label'] as String? ?? n['id'] as String,
              kind: StudioNodeKind.values.byName(n['kind'] as String),
              parentId: n['parentId'] as String?,
              position: _vec(n['position'], Vec3.zero),
              size: _vec(n['size'], Vec3.one),
              scale: _vec(n['scale'], Vec3.one),
              rotation: r == null
                  ? Quat.identity
                  : Quat(r[0], r[1], r[2], r[3]),
              color: n['color'] as int? ?? 0x7e9cb2,
            );
          }).toList();
          next = StudioModeling.addNodes(doc, nodes);
          ids.addAll(nodes.map((n) => n.id));
        case 'resize_shape':
          final id = arguments['targetId'] as String;
          final node = doc.nodes
              .where((n) => n.id == id && n.kind.isPrimitive)
              .firstOrNull;
          if (node == null) {
            return AgentResult(
              AgentStatus.invalid,
              message: 'Choose an authored primitive.',
            );
          }
          next = doc.copyWith(
            nodes: doc.nodes.map(
              (n) => n.id == id
                  ? n.copyWith(size: _vec(arguments['size'], Vec3.one))
                  : n,
            ),
          );
          ids.add(id);
        case 'create_character_blockout':
          next = StudioModeling.characterBlockout(
            doc,
            id: arguments['id'] as String,
            label: arguments['label'] as String? ?? 'Character',
            height: (arguments['height'] as num?)?.toDouble() ?? 1.8,
            position: _vec(arguments['position'], Vec3.zero),
            color: arguments['color'] as int? ?? 0x7e9cb2,
          );
          ids.addAll(next.nodes.skip(doc.nodes.length).map((n) => n.id));
        default:
          return AgentResult(AgentStatus.unsupported);
      }
      context.checkCancelled();
      scene.apply(next);
      onChanged();
      return AgentResult(
        AgentStatus.ok,
        revision: revision,
        affectedIds: ids,
        data: {
          'documentId': doc.id,
          'nodeIds': ids,
          'canUndo': scene.canUndo,
          'saved': false,
        },
      );
    } on ArgumentError {
      return AgentResult(
        AgentStatus.invalid,
        message:
            'Invalid node IDs, hierarchy, dimensions or transform. No changes applied.',
      );
    } on StateError {
      return AgentResult(
        AgentStatus.unavailable,
        message: 'Scene changed or history is unavailable. Refresh state.',
      );
    }
  }
}
