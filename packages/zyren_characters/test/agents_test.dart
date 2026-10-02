import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_characters/agents.dart';
import 'package:zyren_gltf_timeline/agents.dart';
import 'package:zyren_navigation/agents.dart';
import 'package:zyren_physics/agents.dart';
import 'package:zyren_timeline/agents.dart';
import '../example/walkthrough_scene.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  late WalkthroughScene demo;
  late SceneEngine engine;
  late AgentRegistry registry;
  late AttachmentScope scope;
  late CharacterAgentProvider character;
  late NavigationAgentProvider navigation;
  late ModelAnimationAgentProvider model;
  late TimelineAgentProvider timeline;
  late PhysicsAgentProvider physics;
  var revision = 0, commands = 0, demands = 0;
  bool available() {
    for (Object3D? node = demo.model; node != null; node = node.parent) {
      if (identical(node, demo.scene)) return true;
    }
    return false;
  }

  void command(String name, void Function() apply) {
    apply();
    revision++;
    commands++;
  }

  setUp(() async {
    revision = 0;
    commands = 0;
    demands = 0;
    demo = await WalkthroughScene.load();
    engine = await SceneEngine.create(
      scene: demo.scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [demo.timeline, demo.character],
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
    demo.character.pause();
    registry = AgentRegistry(
      grantedScopes: {
        'characters.playback',
        'timeline.playback',
        'physics.move',
      },
    );
    scope = AttachmentScope();
    character = CharacterAgentProvider(
      character: demo.character,
      instanceId: 'robot',
      sourceId: 'fixture/robot',
      readRevision: () => revision,
      isAvailable: available,
      runCommand: command,
    )..register(registry, scope);
    navigation = NavigationAgentProvider(
      mesh: demo.navigation,
      instanceId: 'floor',
      sourceId: 'fixture/floor',
      isAvailable: available,
    )..register(registry, scope);
    model = ModelAnimationAgentProvider(
      model: demo.model,
      instanceId: 'rig',
      sourceId: 'fixture/robot.gltf',
      readRevision: () => revision,
      isAvailable: available,
    )..register(registry, scope);
    timeline = TimelineAgentProvider(
      timeline: demo.timeline,
      instanceId: 'clock',
      readRevision: () => revision,
      isAvailable: available,
      runCommand: command,
    )..register(registry, scope);
    physics = PhysicsAgentProvider(
      physics: demo.physics,
      bodies: {'robot-body': demo.body},
      instanceId: 'world',
      readRevision: () => revision,
      isAvailable: available,
      runCommand: command,
    )..register(registry, scope);
  });
  tearDown(() async {
    scope.close();
    await scope.whenClosed;
    registry.dispose();
    await engine.dispose();
    await demo.close();
  });
  Future<AgentResult> call(
    AgentProvider p,
    String tool,
    Map<String, Object?> arguments, {
    int? expected,
    String? key,
  }) => registry.call(
    providerId: p.id,
    instanceId: p.instanceId,
    tool: tool,
    arguments: arguments,
    expectedRevision: expected,
    idempotencyKey: key,
  );

  test(
    'discovery, shared conformance and passive queries preserve demand and state',
    () async {
      expect((registry.discover()['providers'] as List).length, 5);
      final sceneRevision = demo.scene.revision;
      for (final (provider, arguments)
          in <(AgentProvider, Map<String, Object?>)>[
            (character, {}),
            (model, {'collection': 'nodes'}),
            (timeline, {}),
            (physics, {}),
          ]) {
        expect(
          await AgentConformance.checkRead(
            registry: registry,
            provider: provider,
            tool: 'inspect',
            arguments: arguments,
          ),
          isEmpty,
        );
      }
      final path = await call(navigation, 'find_path', {
        'start': [1.8, 0, .2],
        'goal': [.2, 0, 1.8],
      });
      expect(path.status, AgentStatus.ok);
      expect(path.data['lengthMetres'], closeTo(demo.route.length, 1e-9));
      final clips = await call(model, 'inspect', {'collection': 'clips'});
      expect((clips.data['items'] as List).single['name'], 'walk');
      expect(demo.scene.revision, sceneRevision);
      expect(revision, 0);
      expect(commands, 0);
      expect(demands, 0);
      final metadata = model.describeObject(
        demo.model.nodes[4]!.children.single,
      )!;
      expect(metadata.sourceId, 'fixture/robot.gltf#node/4');
      expect(
        character
            .describeObject(demo.model.nodes[4]!.children.single)!
            .properties['characterState'],
        'idle',
      );
    },
  );
  test(
    'host commands, retries, stale revisions and denied scopes use the registry',
    () async {
      final resumed = await call(
        character,
        'playback',
        {'action': 'resume'},
        expected: 0,
        key: 'resume-1',
      );
      expect(resumed.status, AgentStatus.ok);
      expect(resumed.revision, 1);
      final retried = await call(
        character,
        'playback',
        {'action': 'resume'},
        expected: 0,
        key: 'resume-1',
      );
      expect(retried.status, AgentStatus.ok);
      expect(commands, 1);
      expect(
        (await call(
          character,
          'playback',
          {'action': 'transition', 'state': 'walk'},
          expected: 0,
          key: 'stale',
        )).status,
        AgentStatus.stale,
      );
      expect(
        (await call(
          character,
          'playback',
          {'action': 'transition', 'state': 'walk'},
          expected: 1,
          key: 'walk',
        )).status,
        AgentStatus.ok,
      );
      expect(demo.character.currentState, 'walk');
      final denied = AgentRegistry();
      final deniedScope = AttachmentScope();
      character.register(denied, deniedScope);
      expect(
        (await denied.call(
          providerId: character.id,
          instanceId: character.instanceId,
          tool: 'playback',
          arguments: {'action': 'pause'},
          expectedRevision: revision,
          idempotencyKey: 'denied',
        )).status,
        AgentStatus.denied,
      );
      deniedScope.close();
      await deniedScope.whenClosed;
      denied.dispose();
      expect(
        (await call(
          character,
          'playback',
          {'action': 'transition'},
          expected: revision,
          key: 'missing',
        )).status,
        AgentStatus.invalid,
      );
      expect(
        (await call(character, 'inspect', {'limit': 33})).status,
        AgentStatus.invalid,
      );
    },
  );
  test(
    'physics targets leave stepping to the existing owner and timeline seek works',
    () async {
      final oldPosition = demo.body.state.pose.position;
      final result = await call(
        physics,
        'set_target',
        {
          'bodyId': 'robot-body',
          'position': [.4, .7, .4],
        },
        expected: 0,
        key: 'move',
      );
      expect(result.status, AgentStatus.ok);
      expect(result.affectedIds, ['robot-body']);
      expect(demo.body.state.pose.position, oldPosition);
      demo.physics.advance(.02);
      revision++;
      expect(
        (demo.root.position - const Vec3(.4, .7, .4)).length,
        lessThan(1e-5),
      );
      expect(
        (await call(
          timeline,
          'playback',
          {'action': 'seek', 'seconds': .5},
          expected: revision,
          key: 'seek',
        )).status,
        AgentStatus.ok,
      );
      expect(demo.timeline.position, const Duration(milliseconds: 500));
      demo.physics.removeBody(demo.root);
      expect(
        (await call(
          physics,
          'set_target',
          {
            'bodyId': 'robot-body',
            'position': [0, 0, 0],
          },
          expected: revision,
          key: 'removed',
        )).status,
        AgentStatus.stale,
      );
    },
  );
  test(
    'removed targets, cancelled calls and scope cleanup are explicit',
    () async {
      final cancellation = AgentCancellation()..cancel();
      expect(
        (await registry.call(
          providerId: character.id,
          instanceId: character.instanceId,
          tool: 'inspect',
          cancellation: cancellation,
        )).status,
        AgentStatus.cancelled,
      );
      demo.scene.remove(demo.root);
      expect((await call(character, 'inspect', {})).status, AgentStatus.stale);
      expect(
        (await call(model, 'inspect', {'collection': 'nodes'})).status,
        AgentStatus.stale,
      );
      expect(model.describeObject(demo.model.nodes[4]!), isNull);
      scope.close();
      await scope.whenClosed;
      expect(registry.discover()['providers'], isEmpty);
      expect(
        (await call(character, 'inspect', {})).status,
        AgentStatus.unavailable,
      );
    },
  );
}
