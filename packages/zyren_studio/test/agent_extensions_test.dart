import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_agents/plugins.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/modeling_agents.dart';
import 'package:zyren_studio/agent_extensions.dart';
import 'support/renderer.dart';

void main() {
  test(
    'failed Studio binding attachment rolls back every advertised provider',
    () async {
      final scene = StudioScene(
        StudioDocument(id: 'ext', title: 'Extension', nodes: []),
      );
      final registry = AgentRegistry();
      final owner = StudioAgentExtensionContext(
        scene: scene,
        agents: registry,
        isAvailable: () => true,
        onChanged: () {},
        usePlugin: (_) {},
        deferRegistration: true,
      );
      final provider = StudioModelingAgentProvider(
        scene: scene,
        instanceId: 'duplicate',
        isAvailable: () => true,
        onChanged: () {},
        hostRevision: () => 0,
      );
      owner.register(provider);
      owner.register(provider);
      await expectLater(
        SceneEngine.create(
          scene: scene.scene,
          camera: scene.camera,
          rendererFactory: () async => TestRenderer([]),
          plugins: [
            AgentRegistryPlugin(registry),
            owner.binding('studio.binding.test', {}),
          ],
        ),
        throwsA(isA<Object>()),
      );
      expect(registry.discover()['providers'], isEmpty);
      owner.dispose();
      registry.dispose();
    },
  );

  test(
    'Studio defers providers until runtime attachment and retires on detach',
    () async {
      final scene = StudioScene(
        StudioDocument(id: 'ext', title: 'Extension', nodes: []),
      );
      final registry = AgentRegistry();
      final owner = StudioAgentExtensionContext(
        scene: scene,
        agents: registry,
        isAvailable: () => true,
        onChanged: () {},
        usePlugin: (_) {},
        deferRegistration: true,
      );
      final lease = owner.register(
        StudioModelingAgentProvider(
          scene: scene,
          instanceId: 'extension',
          isAvailable: () => true,
          onChanged: () {},
          hostRevision: () => 0,
        ),
      );
      expect(registry.discover()['providers'], isEmpty);
      final bridge = AgentRegistryPlugin(registry);
      final binding = owner.binding('studio.binding.test', {});
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [bridge, binding],
      );
      final first =
          (registry.discover()['providers'] as List).single['registrationId'];
      await engine.updatePlugins([bridge]);
      expect(registry.discover()['providers'], isEmpty);
      await engine.updatePlugins([bridge, binding]);
      expect(
        (registry.discover()['providers'] as List).single['registrationId'],
        isNot(first),
      );
      final lateLease = owner.register(
        StudioModelingAgentProvider(
          scene: scene,
          instanceId: 'loaded-later',
          isAvailable: () => true,
          onChanged: () {},
          hostRevision: () => 0,
        ),
      );
      expect((registry.discover()['providers'] as List).length, 2);
      lateLease.dispose();
      expect((registry.discover()['providers'] as List).length, 1);
      lease.dispose();
      expect(registry.discover()['providers'], isEmpty);
      owner.dispose();
      await engine.dispose();
      registry.dispose();
    },
  );

  test(
    'Studio cleanup drains every registration even when one cleanup fails',
    () {
      final registry = AgentRegistry();
      final owner = StudioAgentExtensionContext(
        scene: StudioScene(
          StudioDocument(id: 'ext', title: 'Extension', nodes: []),
        ),
        agents: registry,
        isAvailable: () => true,
        onChanged: () {},
        usePlugin: (_) {},
      );
      var cleaned = false;
      owner.keep(Registration(() => cleaned = true));
      owner.keep(Registration(() => throw StateError('cleanup failed')));
      expect(owner.dispose, throwsStateError);
      expect(cleaned, isTrue);
      owner.dispose();
      registry.dispose();
    },
  );

  test(
    'runtime provider registers, retires and reattaches with a new identity',
    () async {
      final scene = StudioScene(
        StudioDocument(id: 'plugins', title: 'Plugins', nodes: []),
      );
      final registry = AgentRegistry(grantedScopes: {'studio.edit'});
      final bridge = AgentRegistryPlugin(registry);
      AgentProviderPlugin adapter() => AgentProviderPlugin(
        id: 'test.modeling-tools',
        runtimeDependencies: {},
        createProviders: (_) => [
          StudioModelingAgentProvider(
            scene: scene,
            instanceId: 'main',
            isAvailable: () => true,
            onChanged: () {},
            hostRevision: () => 0,
          ),
        ],
      );
      final engine = await SceneEngine.create(
        scene: scene.scene,
        camera: scene.camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [bridge, adapter()],
      );
      final first =
          (registry.discover()['providers'] as List).single['registrationId'];
      await engine.updatePlugins([bridge]);
      expect(registry.discover()['providers'], isEmpty);
      await engine.updatePlugins([bridge, adapter()]);
      expect(
        (registry.discover()['providers'] as List).single['registrationId'],
        isNot(first),
      );
      await engine.dispose();
      expect(registry.discover()['providers'], isEmpty);
      registry.dispose();
    },
  );
}
