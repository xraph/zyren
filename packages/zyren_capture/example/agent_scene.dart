import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_audio/agents.dart';
import 'package:zyren_configurator/zyren_configurator.dart';
import 'package:zyren_configurator/agents.dart';
import 'package:zyren_capture/native_capture.dart';
import 'package:zyren_capture/agents.dart';
import 'package:zyren_capture/effects_agents.dart';
import 'package:zyren_devtools/agents.dart';
import 'package:zyren_devtools/io.dart';

/// Host-started MCP on stdio using the shared devtools protocol. No TCP listener.
/// This fixture owns a headless capture view; presented-frame evidence is unknown.
Future<void> main() async {
  final scene = Scene(),
      body = scene.add(
        Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(.1, .3, .9))),
      );
  final listener = scene.add(Group());
  final config = SceneConfigurator(
    catalog: ConfigurationCatalog(
      id: 'fixture',
      revision: 1,
      slots: [
        ConfigurationSlot(
          id: 'finish',
          options: [
            ConfigurationOption(id: 'blue'),
            ConfigurationOption(id: 'red', materials: {'body': 'red'}),
          ],
        ),
      ],
    ),
    targets: {'body': body},
    materials: {'red': UnlitMaterial(color: const Color3(.9, .1, .1))},
  );
  final configProvider = ConfiguratorAgentProvider(
    controller: config,
    scene: scene,
    sceneId: 'scene',
    documentId: 'fixture',
    instanceId: 'config',
  );
  final audio = SpatialAudio(
    root: scene,
    listener: AudioListener(listener),
    offline: true,
  );
  audio.add(
    id: 'body-tone',
    node: body,
    samples: Float32List.fromList(List.filled(4800, .05)),
    settings: EmitterSettings(loop: true),
  );
  final capture = nativeCapture(
    scene: scene,
    sceneId: 'scene',
    documentId: 'fixture',
    outputParent: Directory.systemTemp,
  );
  final captureProvider = CaptureAgentProvider(
    manager: capture,
    instanceId: 'capture',
    maxDimension: 64,
    maxFrames: 4,
  );
  final registry = AgentRegistry(
    grantedScopes: {
      'configurator.write',
      'audio.write',
      'capture.write',
      'effects.write',
    },
  );
  final camera = CapturePlan(size: PhysicalSize(64, 64)).cameraAt(0);
  final registrations = [
    registry.register(configProvider),
    registry.register(
      AudioAgentProvider(
        audio: audio,
        sceneId: 'scene',
        documentId: 'fixture',
        instanceId: 'audio',
      ),
    ),
    captureProvider.register(registry),
    registry.register(
      EffectsAgentProvider(
        scene: scene,
        sceneId: 'scene',
        documentId: 'fixture',
        instanceId: 'effects',
      ),
    ),
    registry.register(
      AgentViewportProvider(
        sceneId: 'scene',
        documentId: 'fixture',
        instanceId: 'capture-view',
        scene: scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(64, 64, devicePixelRatio: 1),
        metadata: configProvider.metadata,
        hostState: () => {
          'viewKind': 'headless capture fixture',
          'displayed': false,
          'presentedFrame': 'unknown',
          'captureExtent': 'scene pixels only',
        },
      ),
    ),
  ];
  final bridge = AgentDevtoolsBridge(registry);
  try {
    await serveDevtoolsMcp(
      input: stdin,
      output: stdout.writeln,
      agentsEnabled: true,
      call: (name, args) => bridge.call(name, args),
    );
  } finally {
    for (final registration in registrations.reversed) {
      registration.dispose();
    }
    registry.dispose();
    await capture.close();
    audio.close();
    config.close();
  }
}
