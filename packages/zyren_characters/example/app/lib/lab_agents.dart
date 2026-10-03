import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_characters/agents.dart';
import 'package:zyren_characters/locomotion_agents.dart';
import 'package:zyren_navigation/world_agents.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'character_lab_scene.dart';

final class CharacterLabAgents extends ScenePlugin {
  final CharacterLabScene lab;
  final AgentRegistry registry;
  late final CharacterLocomotionAgentProvider locomotion;
  late final NavigationWorldAgentProvider navigation;
  ViewportMetrics viewport = const ViewportMetrics(1, 1);
  bool attached = false;
  final bool recordPresentation;
  AgentPresentedFrame? frame;
  CharacterLabAgents(
    this.lab,
    this.registry, {
    this.recordPresentation = false,
  });
  @override
  String get id => 'example.character-lab.agents';
  @override
  Set<String> get dependencies => {lab.character.id, lab.physics.id};
  void command(String name, void Function() apply) {
    apply();
    lab.revision++;
  }

  @override
  void attach(PluginContext context) {
    attached = true;
    bool available() => attached && !lab.removed;
    final character = CharacterAgentProvider(
      character: lab.character,
      instanceId: 'biped',
      sourceId: 'lab/skin.gltf',
      readRevision: () => lab.revision,
      isAvailable: available,
      runCommand: command,
    )..register(registry, context.scope);
    locomotion = CharacterLocomotionAgentProvider(
      motor: lab.motor,
      rig: lab.rig,
      instanceId: 'biped',
      readRevision: () => lab.revision,
      isAvailable: available,
      runCommand: command,
      moveTo: lab.setGoal,
      lookAt: (target) => lab.lookTarget = target,
      footTarget: (joint, target) {
        if (joint != 3 && joint != 6) {
          throw ArgumentError('Only foot joints accept contact targets.');
        }
        lab.footTargets[joint] = target;
      },
      retarget: (enabled) => lab.retargetEnabled = enabled,
    )..register(registry, context.scope);
    navigation = NavigationWorldAgentProvider(
      world: lab.navigation,
      instanceId: 'floor',
      isAvailable: () => attached,
      runCommand: command,
      rebuild: () => NavigationBaker(
        settings: lab.navigation.mesh.settings,
      ).bake(lab.navigation.mesh.geometry),
    )..register(registry, context.scope);
    context.scope.keep(
      registry.register(
        AgentViewportProvider(
          instanceId: 'main',
          documentId: 'character-lab',
          sceneId: 'character-lab',
          scene: context.scene,
          camera: () => context.camera,
          viewport: () => viewport,
          presentedFrame: () => frame,
          documentRevision: () => lab.revision,
          units: 'metres',
          metadata: character.describeObject,
          hostState: () => {
            'mode': 'character-lab',
            'undo': 'unsupported-in-example',
          },
        ),
      ),
    );
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    viewport = ViewportMetrics(frame.width.toDouble(), frame.height.toDouble());
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    if (!recordPresentation) return;
    frame = AgentPresentedFrame(
      id: 'character-lab/${info.number}',
      sceneRevision: context.scene.revision,
      cameraRevision: context.camera.revision,
      cameraRuntimeId: context.camera.id,
      logicalWidth: viewport.width,
      logicalHeight: viewport.height,
      devicePixelRatio: viewport.devicePixelRatio,
      presentedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  @override
  void detach(PluginContext context) {
    attached = false;
  }
}
