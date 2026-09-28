import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'animation_scene.dart';

void main() => runApp(const AnimationLabApp());

class AnimationLabApp extends StatelessWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  final bool autoplay;
  const AnimationLabApp({
    super.key,
    this.runtime,
    this.presentation = PresentationPolicy.requireNative,
    this.autoplay = true,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: _AnimationLab(
      runtime:
          runtime ??
          (Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : Platform.isIOS || Platform.isMacOS
              ? const SceneRuntime.nativeMetal()
              : const SceneRuntime()),
      presentation: presentation,
      autoplay: autoplay,
    ),
  );
}

class _AnimationLab extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final bool autoplay;
  const _AnimationLab({
    required this.runtime,
    required this.presentation,
    required this.autoplay,
  });
  @override
  State<_AnimationLab> createState() => _AnimationLabState();
}

class _AnimationLabState extends State<_AnimationLab> {
  late final SceneController controller;
  final actions = <AnimationAction>[];
  StreamSubscription<FrameStats>? subscription;
  int selected = 0;
  AnimationAction get action => actions[selected];
  @override
  void initState() {
    super.initState();
    final demo = AnimationLabScene(autoplay: widget.autoplay);
    controller = SceneController(
      runtime: widget.runtime,
      scene: demo.scene,
      camera: demo.camera,
      options: EngineOptions(presentation: widget.presentation),
      colorPipeline: ColorPipeline(),
    );
    for (final mixer in demo.mixers) {
      controller.use(mixer);
    }
    actions.addAll(demo.actions);
    subscription = controller.frameStats.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void edit(void Function() change) => setState(change);
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                const Text('Animation', style: TextStyle(fontSize: 18)),
                SegmentedButton<int>(
                  key: const ValueKey('AnimatedModel'),
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Left')),
                    ButtonSegment(value: 1, label: Text('Right')),
                  ],
                  selected: {selected},
                  onSelectionChanged: (value) =>
                      edit(() => selected = value.single),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('Playback'),
                  tooltip: action.isPlaying ? 'Pause' : 'Play',
                  icon: Icon(action.isPlaying ? Icons.pause : Icons.play_arrow),
                  onPressed: () => edit(() {
                    if (action.isPlaying) {
                      action.pause();
                    } else {
                      action.resume();
                    }
                  }),
                ),
                IconButton(
                  key: const ValueKey('Restart'),
                  tooltip: 'Restart',
                  icon: const Icon(Icons.replay),
                  onPressed: () => edit(() => action.seek(Duration.zero)),
                ),
                Expanded(
                  child: Slider(
                    key: const ValueKey('Playhead'),
                    label: '${action.timeSeconds.toStringAsFixed(2)} s',
                    value: action.timeSeconds,
                    max: action.clip.durationSeconds,
                    onChanged: (value) => edit(
                      () => action.seek(
                        Duration(microseconds: (value * 1e6).round()),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 46,
                  child: Text(
                    '${action.timeSeconds.toStringAsFixed(1)} s',
                    textAlign: TextAlign.end,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButton<AnimationLoop>(
                    key: const ValueKey('Loop'),
                    value: action.loop,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: AnimationLoop.once,
                        child: Text('Once'),
                      ),
                      DropdownMenuItem(
                        value: AnimationLoop.repeat,
                        child: Text('Repeat'),
                      ),
                      DropdownMenuItem(
                        value: AnimationLoop.pingPong,
                        child: Text('Ping-pong'),
                      ),
                    ],
                    onChanged: (value) => edit(() => action.loop = value!),
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 110,
                  child: DropdownButton<double>(
                    key: const ValueKey('Speed'),
                    value: action.speed,
                    isExpanded: true,
                    items: [
                      for (final speed in [-2.0, -1.0, 0.0, .5, 1.0, 2.0])
                        DropdownMenuItem(
                          value: speed,
                          child: Text('${speed}x speed'),
                        ),
                    ],
                    onChanged: (value) => edit(() => action.speed = value!),
                  ),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Shared clip · independent playback',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final aspect =
                    constraints.maxWidth / math.max(1, constraints.maxHeight);
                final distance = math.max(
                  3.8,
                  2.4 / (math.tan(.5) * math.max(.1, aspect)),
                );
                controller.camera.position = Vec3(0, .4, distance);
                return SceneView(controller: controller);
              },
            ),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    unawaited(subscription?.cancel());
    controller.dispose();
    super.dispose();
  }
}
