import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_tools/zyren_tools.dart';
import 'package:zyren_studio/agents.dart';
import 'package:zyren_studio/authoring_agents.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/zyren_studio.dart';
import '../../zyren/test/support/fakes.dart';
import 'studio_test.dart' show fixture;

void main() {
  test(
    'authoring provider shares history, enforces grants, retries and stale revisions',
    () async {
      final scene = StudioScene(fixture());
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [scene.tools, scene.engineering],
      );
      addTearDown(engine.dispose);
      var available = true;
      final provider = StudioAuthoringAgentProvider(
        scene: scene,
        instanceId: 'authoring',
        isAvailable: () => available,
        hostRevision: () => 0,
        onChanged: () {},
      );
      final registry = AgentRegistry(grantedScopes: {'studio.edit'})
        ..register(provider);
      addTearDown(registry.dispose);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'definitions',
        ),
        isEmpty,
      );
      final denied = AgentRegistry()..register(provider);
      addTearDown(denied.dispose);
      final arguments = <String, Object?>{
        'targetId': 'box',
        'kind': 'standard',
        'color': 0xabcdef,
        'metallic': .6,
      };
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'set_material',
          arguments: arguments,
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      final before = provider.revision;
      Future<AgentResult> edit() => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'set_material',
        arguments: arguments,
        expectedRevision: before,
        idempotencyKey: 'material',
      );
      expect((await edit()).status, AgentStatus.ok);
      final after = scene.capture().encode();
      expect((await edit()).status, AgentStatus.ok);
      expect(scene.capture().encode(), after);
      expect((scene.objects['box'] as Mesh).material, isA<StandardMaterial>());
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'remove',
          arguments: {'targetId': 'box'},
          expectedRevision: before,
          idempotencyKey: 'stale',
        )).status,
        AgentStatus.stale,
      );
      expect(scene.undo(), isTrue);
      expect((scene.objects['box'] as Mesh).material, isA<DiffuseMaterial>());
      available = false;
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'add_box',
          arguments: {'id': 'new'},
          expectedRevision: provider.revision,
          idempotencyKey: 'busy',
        )).status,
        AgentStatus.unavailable,
      );
    },
  );

  test(
    'shared registry discovers reads, permissions, edits, retries and disposal',
    () async {
      final scene = StudioScene(fixture());
      final gizmo = TransformGizmoPlugin();
      scene.registerHelper(gizmo.owns);
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [scene.tools, gizmo, scene.engineering],
      );
      addTearDown(engine.dispose);
      var allowed = true;
      final commands = StudioCommands(
        scene: scene,
        sessionId: 'test-session',
        isAllowed: (_) => allowed,
        isAvailable: () => true,
      );
      final provider = StudioAgentProvider(
        commands: commands,
        screenContext: () => {'viewportId': 'main'},
        hostRevision: () => 0,
      );
      final registry = AgentRegistry(
        grantedScopes: {'studio.select', 'studio.edit'},
      );
      addTearDown(registry.dispose);
      final lease = registry.register(provider);
      expect(
        (registry.discover()['providers'] as List).single['providerId'],
        'zyren.studio',
      );
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'state',
        ),
        isEmpty,
      );
      final nodes = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'nodes',
        arguments: {'limit': 1},
      );
      expect(nodes.status, AgentStatus.ok);
      expect((nodes.data['nodes'] as List).length, 1);
      expect(nodes.data['nextOffset'], 1);
      final deniedRegistry = AgentRegistry();
      deniedRegistry.register(provider);
      addTearDown(deniedRegistry.dispose);
      expect(
        (await deniedRegistry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'transform',
          expectedRevision: provider.revision,
          idempotencyKey: 'deny',
          arguments: {
            'targetId': 'box',
            'position': [5, 2, 3],
          },
        )).status,
        AgentStatus.denied,
      );
      scene.tools.select(scene.objects['box']);
      await Future<void>.delayed(Duration.zero);
      final before = provider.revision;
      Future<AgentResult> move() => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'transform',
        expectedRevision: before,
        idempotencyKey: 'move',
        arguments: {
          'targetId': 'box',
          'position': [5, 2, 3],
        },
      );
      final changed = await move();
      expect(changed.status, AgentStatus.ok);
      expect(changed.revision, provider.revision);
      expect(scene.objects['box']!.position.x, 5);
      expect((await move()).revision, changed.revision);
      expect(commands.sequence, 1);
      expect(scene.capture().nodes.length, 2);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'undo',
          expectedRevision: before,
          idempotencyKey: 'stale',
        )).status,
        AgentStatus.stale,
      );
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'undo',
          expectedRevision: provider.revision,
          idempotencyKey: 'undo',
        )).status,
        AgentStatus.ok,
      );
      expect(scene.objects['box']!.position.x, 1);
      final invalid = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'transform',
        expectedRevision: provider.revision,
        idempotencyKey: 'invalid',
        arguments: {
          'targetId': 'box',
          'scale': [1, 0, 1],
        },
      );
      expect(invalid.status, AgentStatus.invalid);
      expect(scene.objects['box']!.scale, const Vec3(2, 1, -1));
      scene.objects['box']!.parent!.remove(scene.objects['box']!);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'select',
          expectedRevision: provider.revision,
          idempotencyKey: 'removed',
          arguments: {'targetId': 'box'},
        )).status,
        AgentStatus.stale,
      );
      allowed = false;
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'redo',
          expectedRevision: provider.revision,
          idempotencyKey: 'revoked',
        )).status,
        AgentStatus.denied,
      );
      lease.dispose();
      commands.dispose();
      expect(registry.discover()['providers'], isEmpty);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'state',
        )).status,
        AgentStatus.unavailable,
      );
    },
  );
}
