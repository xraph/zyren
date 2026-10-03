import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/commands.dart';
import 'package:zyren_studio/zyren_studio.dart';

StudioEditorHostController makeHost({
  bool Function()? isAvailable,
  Future<void> Function(List<ScenePlugin>)? installRuntimePlugins,
}) {
  final scene = StudioScene(
    StudioDocument(id: 'scene', title: 'Scene', nodes: []),
  );
  return StudioEditorHostController(
    services: StudioEditorServices(
      scene: scene,
      commands: StudioCommands(
        scene: scene,
        sessionId: 'test',
        isAllowed: (_) => true,
        isAvailable: isAvailable ?? () => true,
      ),
      agents: AgentRegistry(grantedScopes: const {}),
      isAvailable: isAvailable ?? () => true,
      viewportSnapshot: () => const {
        'viewportId': 'main',
        'pixelVisibility': 'unknown',
      },
      capabilities: () => const {'native.metal'},
      applyDocument: scene.apply,
      installRuntimePlugins: installRuntimePlugins,
    ),
  );
}

class TestPlaySession implements StudioEditorPlaySession {
  int closed = 0, steps = 0;
  @override
  String get id => 'play';
  @override
  bool isPaused = false;
  @override
  void pause() => isPaused = true;
  @override
  void resume() => isPaused = false;
  @override
  void step() => steps++;
  @override
  Future<void> close() async {
    closed++;
  }
}

StudioEditorContribution panelContribution(
  String id, {
  Set<String> dependencies = const {},
}) => StudioEditorContribution(
  id: id,
  version: 1,
  dependencies: dependencies,
  attach: (context) {
    context.registerPanel(
      StudioEditorPanel(
        id: '$id.panel',
        title: 'Panel $id',
        icon: Icons.extension,
        builder: (_, _) => TextField(
          key: ValueKey('$id.field'),
          decoration: const InputDecoration(labelText: 'Contributed field'),
        ),
      ),
    );
    context.registerCommand(
      StudioEditorCommand(
        id: '$id.command',
        label: 'Command $id',
        enabled: (_) => true,
        handler: (_) {},
      ),
    );
  },
);

class ContractRenderer implements SceneRenderer {
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: 'contract-test',
    features: {RenderFeatures.indexedMeshes},
    maxDimension: 64,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}
