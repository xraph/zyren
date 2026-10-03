import 'dart:convert';
import 'dart:io';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_audio/agents.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_configurator/agents.dart';
import 'package:zyren_capture/effects_agents.dart';
import 'package:zyren_devtools/zyren_devtools.dart';
import 'package:zyren_devtools/io.dart';
import 'package:zyren_effects/zyren_effects.dart';

/// Registered last: records scene/camera state after effect preparation and
/// publishes it only if it stayed unchanged through render completion.
final class LabAgentHost extends ScenePlugin {
  final SceneController controller;
  final ConfiguratorAgentProvider configurator;
  final SpatialAudio? Function() audio;
  final ScreenEffectsPlugin effects;
  final bool Function() playbackAllowed;
  final Map<String, Object?> Function() uiState;
  final diagnostics = SceneDevtoolsPlugin();
  late AgentRegistry registry;
  late AgentViewportProvider viewportProvider;
  late EffectsAgentProvider effectsProvider;
  AgentPresentedFrame? presented;
  final _submitted = <int, AgentPresentedFrame>{};
  AgentPresentedFrame? _pending;
  DevtoolsServer? _server;
  File? _rendezvous;
  Directory? _bridgeDirectory;
  Future<void>? _starting;
  bool _closed = false;
  File? get bridgeFile => _rendezvous;
  LabAgentHost({
    required this.controller,
    required this.configurator,
    required this.audio,
    required this.effects,
    required this.playbackAllowed,
    required this.uiState,
  });
  @override
  String get id => 'smaller-lab.agents';
  @override
  Set<String> get dependencies => {'screen-effects', 'zyren.devtools'};
  @override
  void attach(PluginContext context) {
    registry = AgentRegistry(
      grantedScopes: {
        'configurator.write',
        'configurator.camera',
        'audio.write',
        'effects.write',
      },
    );
    context.scope.keep(Registration(registry.dispose));
    effectsProvider = EffectsAgentProvider(
      scene: controller.scene,
      sceneId: 'lab',
      documentId: 'fixture',
      instanceId: 'effects',
      effects: effects.controller,
    );
    viewportProvider = AgentViewportProvider(
      sceneId: 'lab',
      documentId: 'fixture',
      instanceId: 'view',
      scene: controller.scene,
      camera: () => controller.camera,
      viewport: () => (controller.input as ViewportInputSource).viewport,
      presentedFrame: () => presented,
      metadata: configurator.metadata,
      hostState: () => {
        'displayed': true,
        'activeViewport': true,
        'overlays': [],
        'captureExtent':
            'native scene; Flutter overlays are not part of RGBA readback',
        'renderSize': controller.latestFrameStats == null
            ? null
            : {
                'width': controller.latestFrameStats!.physicalSize.width,
                'height': controller.latestFrameStats!.physicalSize.height,
              },
        ...uiState(),
      },
    );
    for (final provider in [configurator, effectsProvider, viewportProvider]) {
      context.scope.keep(registry.register(provider));
    }
    if (audio() case final value?) {
      context.scope.keep(
        registry.register(
          AudioAgentProvider(
            audio: value,
            sceneId: 'lab',
            documentId: 'fixture',
            instanceId: 'audio',
            playbackAllowed: playbackAllowed,
          ),
        ),
      );
    }
    context.scope.listen(controller.presentations, (sample) {
      final record = _submitted.remove(sample.frame.frameId);
      presented = record == null
          ? AgentPresentedFrame(id: '${sample.frame.frameId}')
          : AgentPresentedFrame(
              id: record.id,
              sceneRevision: record.sceneRevision,
              cameraRevision: record.cameraRevision,
              cameraRuntimeId: record.cameraRuntimeId,
              logicalWidth: record.logicalWidth,
              logicalHeight: record.logicalHeight,
              devicePixelRatio: record.devicePixelRatio,
              presentedAt: 'controller+${sample.elapsed.inMicroseconds}us',
            );
    });
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    final metrics = (controller.input as ViewportInputSource).viewport;
    _pending = AgentPresentedFrame(
      id: 'pending',
      sceneRevision: controller.scene.revision,
      cameraRevision: controller.camera.revision,
      cameraRuntimeId: controller.camera.id,
      logicalWidth: metrics.width,
      logicalHeight: metrics.height,
      devicePixelRatio: metrics.devicePixelRatio,
    );
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    final p = _pending;
    if (p != null &&
        p.sceneRevision == controller.scene.revision &&
        p.cameraRevision == controller.camera.revision) {
      _submitted[stats.frameId] = AgentPresentedFrame(
        id: '${stats.frameId}',
        sceneRevision: p.sceneRevision,
        cameraRevision: p.cameraRevision,
        cameraRuntimeId: p.cameraRuntimeId,
        logicalWidth: p.logicalWidth,
        logicalHeight: p.logicalHeight,
        devicePixelRatio: p.devicePixelRatio,
      );
      while (_submitted.length > 8) {
        _submitted.remove(_submitted.keys.first);
      }
    }
  }

  Future<void> startBridge() => _starting ??= _startBridge();

  Future<void> _startBridge() async {
    if (_closed) return;
    final server = _server = await DevtoolsServer.start(
      SceneDiagnostics(diagnostics),
      agents: registry,
    );
    if (_closed) return;
    final directory = _bridgeDirectory = await Directory.systemTemp.createTemp(
      'zyren-smaller-lab-',
    );
    final file = _rendezvous = File(
      '${directory.path}/zyren-smaller-native-bridge.json',
    );
    await file.writeAsString(
      jsonEncode({
        'endpoint': server.endpoint.toString(),
        'token': server.token,
      }),
      flush: true,
    );
    // The credential stays in a local file and is never included in evidence.
    print('ZYREN_SMALLER_BRIDGE_FILE=${file.path}');
  }

  @override
  Future<void> detach(PluginContext context) async {
    _closed = true;
    try {
      await _starting;
    } finally {
      await _server?.close();
      if (_bridgeDirectory != null && await _bridgeDirectory!.exists()) {
        await _bridgeDirectory!.delete(recursive: true);
      }
      presented = null;
      _submitted.clear();
    }
  }
}
