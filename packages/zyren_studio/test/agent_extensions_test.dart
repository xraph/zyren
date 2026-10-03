import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_agents/plugins.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/modeling_agents.dart';
import 'support/renderer.dart';

void main() {
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
