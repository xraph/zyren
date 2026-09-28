import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'geometry_scene.dart';

void main() => runApp(const GeometryLabApp());

class GeometryLabApp extends StatelessWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  final bool autoplay;
  final UnsupportedEffects unsupported;
  const GeometryLabApp({
    super.key,
    this.runtime,
    this.autoplay = true,
    this.presentation = PresentationPolicy.requireNative,
    this.unsupported = UnsupportedEffects.reject,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: _GeometryLab(
      runtime:
          runtime ??
          (Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : Platform.isIOS || Platform.isMacOS
              ? const SceneRuntime.nativeMetal()
              : const SceneRuntime()),
      presentation: presentation,
      autoplay: autoplay,
      unsupported: unsupported,
    ),
  );
}

class _GeometryLab extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final bool autoplay;
  final UnsupportedEffects unsupported;
  const _GeometryLab({
    required this.runtime,
    required this.presentation,
    required this.autoplay,
    required this.unsupported,
  });
  @override
  State<_GeometryLab> createState() => _GeometryLabState();
}

class _GeometryLabState extends State<_GeometryLab> {
  late final GeometryLabScene demo;
  late final SceneController controller;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  @override
  void initState() {
    super.initState();
    demo = GeometryLabScene(
      autoplay: widget.autoplay,
      unsupported: widget.unsupported,
    );
    controller = SceneController(
      runtime: widget.runtime,
      scene: demo.scene,
      camera: demo.camera,
      options: EngineOptions(presentation: widget.presentation),
    );
    controller.use(demo.mixer);
    for (final pattern in demo.patterns) {
      controller.use(pattern);
    }
    subscription = controller.frameStats.listen((value) {
      if (mounted) setState(() => stats = value);
    });
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Animated shader materials',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
                IconButton(
                  key: const ValueKey('Geometry colors'),
                  tooltip: demo.colorful
                      ? 'Reset instance colors'
                      : 'Color instances',
                  icon: Icon(
                    demo.colorful ? Icons.palette : Icons.palette_outlined,
                  ),
                  onPressed: () =>
                      setState(() => demo.setColors(!demo.colorful)),
                ),
                IconButton(
                  key: const ValueKey('Geometry playback'),
                  tooltip: demo.action.isPlaying ? 'Pause' : 'Play',
                  icon: Icon(
                    demo.action.isPlaying ? Icons.pause : Icons.play_arrow,
                  ),
                  onPressed: () => setState(() {
                    if (demo.action.isPlaying) {
                      demo.action.pause();
                    } else {
                      demo.action.resume();
                    }
                  }),
                ),
              ],
            ),
          ),
          _slider(
            'Pose',
            demo.action.timeSeconds,
            0,
            4,
            (value) =>
                demo.action.seek(Duration(microseconds: (value * 1e6).round())),
          ),
          _slider(
            'Width',
            demo.skin.morphWeights.first,
            -.5,
            1.5,
            demo.setWidth,
          ),
          _slider('Stripes', demo.patterns.first.frequency, 1, 16, (value) {
            for (final pattern in demo.patterns) {
              pattern.frequency = value;
            }
          }),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'One skinned ribbon · Twelve instances',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final aspect =
                    constraints.maxWidth / math.max(1, constraints.maxHeight);
                controller.camera.position = Vec3(
                  0,
                  0,
                  math.max(
                    4,
                    2.1 /
                        (math.tan(demo.camera.fieldOfView / 2) *
                            math.max(.1, aspect)),
                  ),
                );
                return SceneView(controller: controller);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                stats == null
                    ? 'Preparing renderer'
                    : '${stats!.drawCalls} draws · ${stats!.uploadedBytes} B uploaded',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) change,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        SizedBox(width: 50, child: Text(label)),
        Expanded(
          child: Slider(
            key: ValueKey('Geometry $label'),
            value: value,
            min: min,
            max: max,
            onChanged: (value) => setState(() => change(value)),
          ),
        ),
        SizedBox(
          width: 36,
          child: Text(value.toStringAsFixed(1), textAlign: TextAlign.end),
        ),
      ],
    ),
  );
}
