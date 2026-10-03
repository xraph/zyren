import 'dart:async';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'package:zyren_interaction/agents.dart';
import 'package:zyren_tools/zyren_tools.dart';

/// The demo grants only selection and undoable transforms. Applications choose
/// their own scopes and keep imported metadata separate from tool definitions.
final class ExampleAgentHost extends ScenePlugin {
  final SceneController controller;
  final SceneInteractionRouter router;
  final SceneToolsPlugin tools;
  final Map<String, Object?> Function()? uiState;
  final inspector = SceneDevtoolsPlugin();
  late AgentRegistry registry;
  late InteractionAgentProvider interactionProvider;
  late AgentViewportProvider viewportProvider;
  DevtoolsServer? _server;
  AgentPresentedFrame? _presented;
  ExampleAgentHost({
    required this.controller,
    required this.router,
    required this.tools,
    this.uiState,
  });
  @override
  String get id => 'interaction-example.agents';
  @override
  Set<String> get dependencies => {
    'zyren.tools',
    'zyren.interaction',
    'zyren.devtools',
  };
  @override
  void attach(PluginContext context) {
    registry = AgentRegistry(
      grantedScopes: {'tools.select', 'tools.transform'},
    );
    context.scope.keep(Registration(registry.dispose));
    interactionProvider = InteractionAgentProvider(
      router: router,
      sceneTools: tools,
      instanceId: 'main',
    );
    viewportProvider = AgentViewportProvider(
      sceneId: 'interaction-demo',
      documentId: 'unsaved-demo',
      instanceId: 'main',
      scene: controller.scene,
      camera: () => controller.camera,
      viewport: () => (controller.input as ViewportInputSource).viewport,
      presentedFrame: () => _presented,
      hostState: () => {
        'selectedRuntimeId': tools.selected?.id,
        'hoveredRuntimeIds': router.hoveredObjects.values
            .map((object) => object.id)
            .toList(),
        'activeMode': 'object-drag',
        'activeViewport': true,
        'focus': controller.input is FocusInputSource
            ? (controller.input as FocusInputSource).hasFocus
            : null,
        'overlays': [],
        ...?uiState?.call(),
        'captureSupport': 'unavailable',
        'renderSize': controller.latestFrameStats == null
            ? null
            : {
                'width': controller.latestFrameStats!.physicalSize.width,
                'height': controller.latestFrameStats!.physicalSize.height,
              },
      },
      metadata: (object) => object is! Mesh
          ? null
          : AgentObjectMetadata(
              sourceId: object.name == null ? null : 'demo:${object.name}',
              semanticType: 'demo-box',
              owningPlugin: 'zyren.interaction',
              provenance: {'source': 'procedural example'},
              actions: [
                'zyren.interaction/main/select',
                'zyren.interaction/main/translate',
              ],
            ),
    );
    for (final provider in [
      viewportProvider,
      interactionProvider,
      DiagnosticsAgentProvider(
        diagnostics: SceneDiagnostics(inspector),
        inspector: inspector,
        instanceId: 'main',
      ),
    ]) {
      context.scope.keep(registry.register(provider));
    }
    context.scope.listen(controller.presentations, (sample) {
      // FrameStats exposes the frame ID and presentation time, not captured
      // scene/camera revisions. Leave those unknown instead of sampling later.
      _presented = AgentPresentedFrame(
        id: '${sample.frame.frameId}',
        presentedAt: 'controller+${sample.elapsed.inMicroseconds}us',
      );
    });
  }

  /// Starts the existing authenticated loopback bridge only on explicit host use.
  Future<DevtoolsServer> startBridge() async => _server ??=
      await DevtoolsServer.start(SceneDiagnostics(inspector), agents: registry);
  @override
  Future<void> detach(PluginContext context) async {
    await _server?.close();
    _server = null;
    _presented = null;
  }
}
