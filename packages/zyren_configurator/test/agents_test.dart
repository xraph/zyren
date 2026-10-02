import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_configurator/zyren_configurator.dart';
import 'package:zyren_configurator/agents.dart';

void main() {
  test(
    'shared discovery, real actions, schema, scope, retry, undo and stale targets',
    () async {
      final scene = Scene(), mesh = Mesh(BoxGeometry(), UnlitMaterial());
      scene.add(mesh);
      final original = mesh.material,
          red = UnlitMaterial(color: const Color3(1, 0, 0));
      final controller = SceneConfigurator(
        catalog: ConfigurationCatalog(
          id: 'catalog',
          revision: 1,
          slots: [
            ConfigurationSlot(
              id: 'finish',
              options: [
                ConfigurationOption(id: 'red', materials: {'body': 'red'}),
              ],
            ),
          ],
        ),
        targets: {'body': mesh},
        materials: {'red': red},
      );
      final provider = ConfiguratorAgentProvider(
        controller: controller,
        scene: scene,
        sceneId: 'scene',
        documentId: 'doc',
        instanceId: 'config',
      );
      final registry = AgentRegistry(grantedScopes: {'configurator.write'}),
          registration = registry.register(provider);
      addTearDown(registry.dispose);
      addTearDown(controller.close);
      expect((registry.discover()['providers'] as List).length, 1);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'inspect',
        ),
        isEmpty,
      );
      final options = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'options',
        arguments: {'slot': 'finish'},
      );
      expect((options.data['options'] as List).single['materials'], {
        'body': 'red',
      });
      expect(provider.metadata(mesh)!.sourceId, 'body');
      final revision = provider.revision;
      Future<AgentResult> apply() => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'apply',
        arguments: {
          'choices': [
            {'slot': 'finish', 'option': 'red'},
          ],
        },
        expectedRevision: revision,
        idempotencyKey: 'apply-1',
      );
      final result = await apply();
      expect(result.status, AgentStatus.ok);
      expect(mesh.material, same(red));
      expect(await apply(), same(result));
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'reset',
          expectedRevision: revision,
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
      expect(mesh.material, same(original));
      final denied = AgentRegistry()..register(provider);
      addTearDown(denied.dispose);
      expect(
        (await denied.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'reset',
          expectedRevision: provider.revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'options',
          arguments: {'slot': 7},
        )).status,
        AgentStatus.invalid,
      );
      scene.remove(mesh);
      expect(provider.metadata(mesh), isNull);
      expect(
        (await registry.call(
          providerId: provider.id,
          instanceId: provider.instanceId,
          tool: 'inspect',
        )).status,
        AgentStatus.stale,
      );
      registration.dispose();
      expect(registry.discover()['providers'], isEmpty);
    },
  );
}
