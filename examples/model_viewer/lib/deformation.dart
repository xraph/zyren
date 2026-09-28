import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'deformation_scene.dart';

void main() => runApp(
  DeformationApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  ),
);

class DeformationApp extends StatelessWidget {
  final SceneRuntime runtime;
  const DeformationApp({super.key, required this.runtime});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: _DeformationView(runtime: runtime),
  );
}

class _DeformationView extends StatefulWidget {
  final SceneRuntime runtime;
  const _DeformationView({required this.runtime});
  @override
  State<_DeformationView> createState() => _DeformationViewState();
}

class _DeformationViewState extends State<_DeformationView> {
  late final SceneController controller;
  late final DeformationRig active;
  late final AnimationAction action;
  late final Registration animation;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      options: EngineOptions(presentation: PresentationPolicy.requireNative),
    );
    controller.scene.background = const Color3(.025, .04, .065);
    controller.camera.position = const Vec3(0, 0, 4.6);
    final geometry = deformationRibbon();
    active = addDeformationRig(
      controller.scene,
      geometry,
      x: -.85,
      color: const Color3(.2, .8, .95),
    );
    final second = addDeformationRig(
      controller.scene,
      geometry,
      x: .85,
      color: const Color3(1, .45, .18),
    );
    second.tip.rotateZ(-.45);
    second.mesh.setMorphWeight(0, -.25);
    controller.scene.add(
      DirectionalLight(
        intensity: 2.5,
        shadow: DirectionalShadow(cascades: 2, distance: 12, normalBias: 0),
      )..lookAt(const Vec3(.4, -.5, -1)),
    );
    controller.scene.add(HemisphereLight(intensity: .4));
    controller.scene.add(
      Mesh(
          PlaneGeometry(width: 6, height: 4),
          StandardMaterial(baseColor: const Color3(.07, .1, .15), roughness: 1),
        )
        ..position = const Vec3(0, 0, -.35)
        ..receiveShadow = true,
    );
    final system = controller.use(AnimationSystem());
    animation = system.add(active.mixer);
    action = active.mixer.play(deformationClip());
    subscription = controller.frameStats.listen((value) {
      if (mounted) setState(() => stats = value);
    });
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    animation.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Expanded(
                  child: Text(
                    'Skin + morph',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: const ValueKey('Deformation playback'),
                  tooltip: action.isPlaying ? 'Pause' : 'Play',
                  onPressed: () => setState(() {
                    if (action.isPlaying) {
                      action.pause();
                    } else {
                      action.resume();
                    }
                  }),
                  icon: Icon(action.isPlaying ? Icons.pause : Icons.play_arrow),
                ),
                DropdownButton<double>(
                  key: const ValueKey('Deformation speed'),
                  value: action.speed,
                  items: [
                    for (final speed in [.5, 1.0, 2.0])
                      DropdownMenuItem(value: speed, child: Text('$speed×')),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => action.speed = value);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 244,
                  child: Row(
                    children: [
                      const Text('Pose'),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('Deformation playhead'),
                          value: action.timeSeconds,
                          max: 4,
                          onChanged: (value) {
                            setState(() {
                              action.seek(
                                Duration(microseconds: (value * 1e6).round()),
                              );
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 244,
                  child: Row(
                    children: [
                      const Text('Width'),
                      Expanded(
                        child: Slider(
                          key: const ValueKey('Deformation morph'),
                          value: active.mesh.morphWeights[0],
                          min: -.5,
                          max: 1.5,
                          onChanged: (value) => setState(
                            () => active.mesh.setMorphWeight(0, value),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              stats == null
                  ? 'Preparing native renderer'
                  : '${stats!.drawCalls} draws · ${stats!.uploadedBytes} B uploaded · ${stats!.readbackBytes} B readback',
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(child: SceneView(controller: controller)),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(
              'Shared geometry. Independent poses. Controls affect the blue mesh.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
