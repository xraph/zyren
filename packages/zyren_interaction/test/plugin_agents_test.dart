import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'package:zyren_interaction/agents.dart';
import 'package:zyren_tools/zyren_tools.dart';
import '../../zyren/test/support/fakes.dart';
import 'router_test.dart' show TestInput;

void main() {
  test(
    'plugin attachment releases gestures, provider selects/transforms/undoes real tools',
    () async {
      final scene = Scene();
      final box = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
      final camera = PerspectiveCamera();
      final input = TestInput();
      final tools = SceneToolsPlugin(
        selectOnTap: false,
        highlightSelection: false,
      );
      final router = SceneInteractionRouter(
        scene: scene,
        camera: () => camera,
        viewport: () => input.viewport,
      );
      router.register(box, (_) {});
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        rendererFactory: () async => TestRenderer([]),
        input: input,
        plugins: [tools, SceneInteractionPlugin(router)],
      );
      final registry = AgentRegistry(
        grantedScopes: {'tools.select', 'tools.transform'},
      );
      final provider = InteractionAgentProvider(
        router: router,
        sceneTools: tools,
        instanceId: 'view',
      );
      final lease = registry.register(provider);
      Future<AgentResult> action(
        String tool,
        Map<String, Object?> args,
        String key,
      ) => registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: tool,
        arguments: args,
        expectedRevision: provider.revision,
        idempotencyKey: key,
      );
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'state',
        ),
        isEmpty,
      );
      final before = provider.revision;
      expect(
        (await action('select', {'runtimeId': box.id}, 'select')).status,
        AgentStatus.ok,
      );
      expect(tools.selected, same(box));
      expect(provider.revision, greaterThan(before));
      expect(
        (await action('translate', {
          'runtimeId': box.id,
          'x': 2,
          'y': 0,
          'z': 0,
        }, 'move')).status,
        AgentStatus.ok,
      );
      expect(box.position, const Vec3(2, 0, 0));
      expect((await action('undo', {}, 'undo')).status, AgentStatus.ok);
      expect(box.position, Vec3.zero);
      expect((await action('redo', {}, 'redo')).status, AgentStatus.ok);
      expect(box.position, const Vec3(2, 0, 0));
      scene.remove(box);
      expect(
        (await action('select', {'runtimeId': box.id}, 'stale')).status,
        AgentStatus.stale,
      );
      lease.dispose();
      await engine.dispose();
      expect(input.interests, isEmpty);
      expect(router.isDisposed, isFalse);
      router.dispose();
      registry.dispose();
      await input.controller.close();
    },
  );
}
