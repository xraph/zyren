import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/modeling_agents.dart';

void main() {
  late StudioScene scene;
  late StudioModelingAgentProvider provider;
  late AgentRegistry registry;
  var command = 0;
  setUp(() {
    scene = StudioScene(StudioDocument(id: 'test', title: 'Test', nodes: []));
    provider = StudioModelingAgentProvider(
      scene: scene,
      instanceId: 'scene',
      isAvailable: () => true,
      onChanged: () {},
      hostRevision: () => 0,
    );
    registry = AgentRegistry(grantedScopes: {'studio.edit'})
      ..register(provider);
  });
  tearDown(() => registry.dispose());
  Future<AgentResult> call(String tool, Map<String, Object?> arguments) =>
      registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: tool,
        expectedRevision: provider.revision,
        idempotencyKey: 'c-${command++}',
        arguments: arguments,
      );
  test(
    'every primitive round-trips, reconstructs and undoes as one batch',
    () async {
      final shapes = StudioNodeKind.values.where((k) => k.isPrimitive).toList();
      final result = await call('create_nodes', {
        'nodes': [
          for (final kind in shapes)
            {
              'id': kind.name,
              'kind': kind.name,
              'size': [2, 3, 4],
            },
        ],
      });
      expect(result.status, AgentStatus.ok);
      final saved = StudioDocument.decode(scene.capture().encode());
      final reopened = StudioScene(saved);
      for (final kind in shapes) {
        expect(reopened.objects[kind.name], isA<Mesh>());
        expect(
          (reopened.objects[kind.name] as Mesh).geometry.vertexCount,
          greaterThan(3),
        );
      }
      expect(scene.undo(), isTrue);
      expect(scene.document.nodes, isEmpty);
      expect(scene.redo(), isTrue);
      expect(scene.document.nodes.length, shapes.length);
    },
  );
  test(
    'invalid batch leaves all existing state and history unchanged',
    () async {
      final before = scene.capture().encode();
      final result = await call('create_nodes', {
        'nodes': [
          {'id': 'x', 'kind': 'sphere'},
          {'id': 'x', 'kind': 'box'},
        ],
      });
      expect(result.status, AgentStatus.invalid);
      expect(scene.capture().encode(), before);
      expect(scene.canUndo, isFalse);
    },
  );
  test(
    'character pivots and dimensions survive persistence and resizing',
    () async {
      final result = await call('create_character_blockout', {
        'id': 'hero',
        'height': 1.8,
      });
      expect(result.status, AgentStatus.ok);
      expect(
        scene.objects['hero-left-elbow']!.parent,
        same(scene.objects['hero-left-shoulder']),
      );
      expect(
        scene.objects['hero-left-forearm']!.parent,
        same(scene.objects['hero-left-elbow']),
      );
      expect(
        (await call('resize_shape', {
          'targetId': 'hero-head',
          'size': [.4, .4, .4],
        })).status,
        AgentStatus.ok,
      );
      final reopened = StudioScene(
        StudioDocument.decode(scene.capture().encode()),
      );
      expect(
        reopened.document.nodes.singleWhere((n) => n.id == 'hero-head').size,
        const Vec3(.4, .4, .4),
      );
      scene.undo();
      expect(
        scene.document.nodes.singleWhere((n) => n.id == 'hero-head').size,
        const Vec3(.28, .32, .28),
      );
    },
  );
  test('version 2 scenes are readable and save as version 3', () {
    final encoded = scene.capture().encode().replaceFirst(
      '"schemaVersion":3',
      '"schemaVersion":2',
    );
    expect(
      StudioDocument.decode(encoded).encode(),
      contains('"schemaVersion":3'),
    );
  });
}
