import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
// Keep the example fixture outside the package dependency graph.
// ignore: avoid_relative_lib_imports
import '../example/app/lib/character_lab_scene.dart';
// Keep the example fixture outside the package dependency graph.
// ignore: avoid_relative_lib_imports
import '../example/app/lib/lab_agents.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'locomotion and generated-navigation providers enforce scoped revisioned commands',
    () async {
      final lab = await CharacterLabScene.load(nativeDeformation: false);
      final registry = AgentRegistry(
        grantedScopes: {'characters.locomotion', 'navigation.edit'},
      );
      final agents = CharacterLabAgents(lab, registry);
      final engine = await SceneEngine.create(
        scene: lab.scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [...lab.plugins, agents],
      );
      try {
        lab.setPaused(true);
        for (final provider in [agents.locomotion, agents.navigation]) {
          expect(
            await AgentConformance.checkRead(
              registry: registry,
              provider: provider,
              tool: 'inspect',
              arguments: {},
            ),
            isEmpty,
          );
        }
        Future<AgentResult> call(
          AgentProvider p,
          String tool,
          Map<String, Object?> arguments, {
          String? key,
          int? expected,
        }) => registry.call(
          providerId: p.id,
          instanceId: p.instanceId,
          tool: tool,
          arguments: arguments,
          expectedRevision: expected,
          idempotencyKey: key,
        );
        final before = lab.revision;
        final denied = AgentRegistry(grantedScopes: {});
        final deniedScope = AttachmentScope();
        agents.locomotion.register(denied, deniedScope);
        expect(
          (await denied.call(
            providerId: agents.locomotion.id,
            instanceId: 'biped',
            tool: 'move_to',
            arguments: {
              'target': [2, 0, 2],
            },
            expectedRevision: before,
            idempotencyKey: 'denied',
          )).status,
          AgentStatus.denied,
        );
        deniedScope.close();
        await deniedScope.whenClosed;
        final move = await call(
          agents.locomotion,
          'move_to',
          {
            'target': [2, 0, 2],
          },
          key: 'move',
          expected: before,
        );
        expect(move.status, AgentStatus.ok);
        expect(lab.follower.goal, const Vec3(2, 0, 2));
        final retry = await call(
          agents.locomotion,
          'move_to',
          {
            'target': [2, 0, 2],
          },
          key: 'move',
          expected: before,
        );
        expect(retry.status, AgentStatus.ok);
        expect(retry.revision, move.revision);
        expect(
          (await call(
            agents.locomotion,
            'look_at',
            {
              'target': [1, 1, 1],
            },
            key: 'stale',
            expected: before,
          )).status,
          AgentStatus.stale,
        );
        for (final (tool, args) in <(String, Map<String, Object?>)>[
          (
            'look_at',
            {
              'target': [1, 1.5, 2],
            },
          ),
          (
            'foot_target',
            {
              'joint': 3,
              'target': [-.16, .1, .2],
            },
          ),
          ('set_retarget', {'enabled': false}),
        ]) {
          expect(
            (await call(
              agents.locomotion,
              tool,
              args,
              key: tool,
              expected: lab.revision,
            )).status,
            AgentStatus.ok,
          );
        }
        expect(
          (await call(
            agents.navigation,
            'set_obstacles',
            {
              'obstacles': [
                {
                  'id': 'barrier',
                  'min': [2, 0, 0],
                  'max': [4, 2, 6],
                },
              ],
            },
            key: 'obstacle',
            expected: agents.navigation.revision,
          )).status,
          AgentStatus.ok,
        );
        expect(lab.follower.intent(const Vec3(1, 0, 1), .1), Vec3.zero);
        expect(
          (await call(
            agents.navigation,
            'rebuild',
            {},
            key: 'bake',
            expected: agents.navigation.revision,
          )).status,
          AgentStatus.ok,
        );
        lab.removeCharacter();
        expect(
          (await call(agents.locomotion, 'inspect', {})).status,
          AgentStatus.stale,
        );
      } finally {
        await engine.dispose();
        await lab.close();
      }
      expect(registry.discover()['providers'], isEmpty);
    },
  );
}
