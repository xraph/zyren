import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_characters/agents.dart';
import 'package:zyren_gltf_timeline/agents.dart';
import 'package:zyren_navigation/agents.dart';
import 'package:zyren_physics/agents.dart';
import 'package:zyren_timeline/agents.dart';
import 'walkthrough_scene.dart';

/// Registers domain tools and their geometric viewport context for this example.
/// A product host should replace the gateway with its own command history.
final class WalkthroughAgents extends ScenePlugin {
  final WalkthroughScene demo;
  final AgentRegistry registry;
  int _commandRevision = 0;
  bool _attached = false;
  ViewportMetrics _viewport = const ViewportMetrics(480, 360);
  WalkthroughAgents(this.demo, this.registry);
  @override
  String get id => 'example.walkthrough.agents';
  @override
  Set<String> get dependencies => {demo.character.id};
  bool _available() {
    if (!_attached) return false;
    for (Object3D? node = demo.model; node != null; node = node.parent) {
      if (identical(node, demo.scene)) return true;
    }
    return false;
  }

  int _revision() => demo.scene.revision + _commandRevision;
  void _command(String name, void Function() apply) {
    apply();
    _commandRevision++;
  }

  @override
  void attach(PluginContext context) {
    _attached = true;
    final character = CharacterAgentProvider(
      character: demo.character,
      instanceId: 'robot',
      sourceId: 'fixture.robot',
      readRevision: _revision,
      isAvailable: _available,
      runCommand: _command,
    )..register(registry, context.scope);
    final model = ModelAnimationAgentProvider(
      model: demo.model,
      instanceId: 'robot-rig',
      sourceId: 'fixture.robot.gltf',
      readRevision: _revision,
      isAvailable: _available,
    )..register(registry, context.scope);
    NavigationAgentProvider(
      mesh: demo.navigation,
      instanceId: 'floor',
      sourceId: 'fixture.floor',
      isAvailable: _available,
    ).register(registry, context.scope);
    TimelineAgentProvider(
      timeline: demo.timeline,
      instanceId: 'clock',
      readRevision: _revision,
      isAvailable: _available,
      runCommand: _command,
    ).register(registry, context.scope);
    PhysicsAgentProvider(
      physics: demo.physics,
      bodies: {'robot-body': demo.body},
      instanceId: 'physics',
      readRevision: _revision,
      isAvailable: _available,
      runCommand: _command,
    ).register(registry, context.scope);
    context.scope.keep(
      registry.register(
        AgentViewportProvider(
          sceneId: 'walkthrough',
          documentId: 'authored-floor',
          instanceId: 'main',
          scene: context.scene,
          camera: () => context.camera,
          viewport: () => _viewport,
          documentRevision: _revision,
          units: 'metres',
          hostState: () => {
            'mode': 'offscreen-walkthrough',
            'displayPresentation': 'unverified',
            'undo': 'unsupported-in-example',
          },
          metadata: (object) {
            final rig = model.describeObject(object),
                state = character.describeObject(object);
            if (rig == null) return state;
            return AgentObjectMetadata(
              sourceId: rig.sourceId,
              semanticType: rig.semanticType,
              owningPlugin: character.id,
              properties: {...rig.properties, ...?state?.properties},
              provenance: rig.provenance,
              actions: [...rig.actions, ...?state?.actions],
            );
          },
        ),
      ),
    );
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _viewport = ViewportMetrics(
      frame.width.toDouble(),
      frame.height.toDouble(),
    );
    _commandRevision++; // Includes action clocks that can move without a pose edit.
  }

  @override
  void detach(PluginContext context) {
    _attached = false;
  }
}
