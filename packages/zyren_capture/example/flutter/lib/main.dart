import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_configurator/zyren_configurator.dart';
import 'package:zyren_configurator/agents.dart';
import 'package:zyren_configurator/viewpoints.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'agent_host.dart';
import 'audio_session.dart';

void main() => runApp(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const SmallerLab(),
  ),
);

class SmallerLab extends StatefulWidget {
  const SmallerLab({super.key});
  @override
  State<SmallerLab> createState() => SmallerLabState();
}

class SmallerLabState extends State<SmallerLab> with WidgetsBindingObserver {
  final scene = Scene()..background = const Color3(.045, .06, .08);
  final camera = PerspectiveCamera(position: const Vec3(0, 1, 5));
  late final Mesh body;
  late final SceneController controller;
  late final SceneConfigurator configurator;
  late final ConfiguratorAgentProvider configProvider;
  late final LabAgentHost host;
  final effects = ScreenEffectsPlugin(
    settings: ScreenEffectsSettings(smaa: null, dithering: false),
  );
  SpatialAudio? audio;
  AudioEmitter? tone;
  late final LabAudioSession audioSession;
  bool blocked = false, narrow = false, busy = false;
  String status = 'Ready', audioStatus = 'Opening native output';
  var _command = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    body = scene.add(
      Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(.1, .35, .95))),
    );
    scene.add(camera);
    final emitter = scene.add(Group()..position = const Vec3(-2, 1, 2));
    try {
      final engine = audio = SpatialAudio(
        root: scene,
        listener: AudioListener(camera),
      );
      tone = engine.add(
        id: 'tone',
        node: emitter,
        samples: Float32List.fromList(
          List.generate(
            48000,
            (i) => .04 * math.sin(2 * math.pi * 440 * i / 48000),
          ),
        ),
        settings: EmitterSettings(loop: true),
      );
      audioStatus = engine.backend;
    } catch (error) {
      audioStatus = 'Audio unavailable: $error';
    }
    audioSession = LabAudioSession(
      suspend: () => audio?.suspend(),
      resume: () => audio?.resume(),
      onError: (error) {
        if (mounted) setState(() => audioStatus = '$error');
      },
    );
    if (Platform.isAndroid || Platform.isIOS) audio?.suspend();
    configurator = SceneConfigurator(
      catalog: ConfigurationCatalog(
        id: 'lab',
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
      materials: {'red': UnlitMaterial(color: const Color3(.95, .1, .08))},
    );
    controller = SceneController(
      scene: scene,
      camera: camera,
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
    );
    configProvider = ConfiguratorAgentProvider(
      controller: configurator,
      scene: scene,
      sceneId: 'lab',
      documentId: 'fixture',
      instanceId: 'config',
      camera: camera,
      viewport: () => (controller.input as ViewportInputSource).viewport,
      viewpoints: ConfigurationViewpoints(
        targets: {'body': body},
        presets: [
          ConfigurationCameraPreset(
            id: 'front',
            position: const Vec3(0, 1, 5),
            target: Vec3.zero,
          ),
          ConfigurationCameraPreset(
            id: 'side',
            position: const Vec3(4, 1, 3),
            target: Vec3.zero,
          ),
        ],
        hotspots: [
          ConfigurationHotspot(
            id: 'body-center',
            targetId: 'body',
            label: 'Body',
            presetId: 'front',
          ),
        ],
      ),
    );
    host = LabAgentHost(
      controller: controller,
      configurator: configProvider,
      audio: () => audio,
      effects: effects,
      playbackAllowed: () => audioSession.allowed,
      uiState: () => {
        'overlays': blocked
            ? [
                {'id': 'review', 'blocksPointer': true},
              ]
            : [],
        'pointerBlockedByUi': blocked,
        'layout': narrow ? 'narrow' : 'desktop',
        'audioStatus': audioStatus,
      },
    );
    controller.use(effects);
    controller.use(host.diagnostics);
    controller.use(host);
    controller.status.addListener(_statusChanged);
  }

  void _statusChanged() {
    if (mounted) setState(() {});
    if (controller.status.value is SceneReady &&
        const bool.fromEnvironment('ZYREN_SMALLER_MCP')) {
      unawaited(host.startBridge());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(audioSession.setForeground(state == AppLifecycleState.resumed));
  }

  Future<void> toggleAudio() async {
    if (tone == null) return;
    if (tone!.isPlaying && audioSession.allowed) {
      tone!.pause();
      await audioSession.pause();
    } else if (await audioSession.play()) {
      tone!.play();
    }
    if (mounted) setState(() {});
  }

  Future<AgentResult> call(
    AgentProvider provider,
    String tool, [
    Map<String, Object?> arguments = const {},
  ]) async {
    final result = await host.registry.call(
      providerId: provider.id,
      instanceId: provider.instanceId,
      tool: tool,
      arguments: arguments,
      expectedRevision: provider.revision,
      idempotencyKey: 'ui-${_command++}',
    );
    if (mounted) {
      setState(
        () => status =
            '${result.status.name}: $tool${result.message == null ? '' : ': ${result.message}'}',
      );
    }
    controller.invalidate();
    return result;
  }

  Future<void> editEffect() async {
    setState(() => busy = true);
    try {
      await call(host.effectsProvider, 'chain', {
        'dithering': !effects.controller.settings.dithering,
        'smaa': effects.controller.settings.smaa == null ? 'low' : 'off',
      });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.status.removeListener(_statusChanged);
    audioSession.dispose();
    audio?.close();
    configurator.close();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = controller.status.value is SceneReady;
    final panel = Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: ready
                    ? () => call(configProvider, 'apply', {
                        'choices': [
                          {'slot': 'finish', 'option': 'blue'},
                        ],
                      })
                    : null,
                child: const Text('Blue'),
              ),
              TextButton(
                onPressed: ready
                    ? () => call(configProvider, 'apply', {
                        'choices': [
                          {'slot': 'finish', 'option': 'red'},
                        ],
                      })
                    : null,
                child: const Text('Red'),
              ),
              TextButton(
                onPressed: ready
                    ? () => call(configProvider, 'camera', {'id': 'side'})
                    : null,
                child: const Text('Side view'),
              ),
              TextButton(
                onPressed: ready && !busy ? editEffect : null,
                child: const Text('SMAA + dither'),
              ),
              TextButton(
                onPressed: tone == null ? null : toggleAudio,
                child: Text(
                  tone?.isPlaying == true && audioSession.allowed
                      ? 'Pause tone'
                      : 'Play tone',
                ),
              ),
              TextButton(
                onPressed: () => setState(() => blocked = !blocked),
                child: const Text('Review overlay'),
              ),
            ],
          ),
        ),
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(
                child: SceneView(
                  controller: controller,
                  key: const ValueKey('viewport'),
                  loadingBuilder: (_) =>
                      const Center(child: CircularProgressIndicator()),
                  errorBuilder: (_, issue, retry) => ZeroState(
                    title: 'Native view unavailable',
                    message: issue.message,
                    actionLabel: 'Retry',
                    onAction: retry,
                  ),
                ),
              ),
              if (blocked)
                Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black54,
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Review blocks viewport input'),
                              TextButton(
                                onPressed: () =>
                                    setState(() => blocked = false),
                                child: const Text('Close review'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('$status · $audioStatus', maxLines: 3),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smaller plugins lab'),
        actions: [
          IconButton(
            tooltip: 'Toggle narrow viewport',
            onPressed: () => setState(() => narrow = !narrow),
            icon: const Icon(Icons.width_normal),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(width: narrow ? 360 : double.infinity, child: panel),
        ),
      ),
    );
  }
}
