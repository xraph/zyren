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
  late final Registration tapGesture;
  Line? selection;
  String selectionLabel = 'Tap a ribbon to inspect its triangle';
  int pickGeneration = 0;
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
    tapGesture = controller.input.registerGesture(SceneGesture.tap);
    for (final pattern in demo.patterns) {
      controller.use(pattern);
    }
    subscription = controller.frameStats.listen((value) {
      if (mounted) setState(() => stats = value);
    });
  }

  @override
  void dispose() {
    tapGesture.dispose();
    unawaited(subscription?.cancel());
    controller.dispose();
    super.dispose();
  }

  void clearSelection() {
    pickGeneration++;
    if (selection case final line?) controller.scene.remove(line);
    selection = null;
    selectionLabel = 'Tap a ribbon to inspect its triangle';
  }

  Future<void> select(ScenePointerEvent event) async {
    if (event.phase != ScenePointerPhase.tap) return;
    demo.action.pause();
    clearSelection();
    final generation = pickGeneration;
    try {
      final hit = await controller.pick(event.point);
      if (!mounted || generation != pickGeneration) return;
      setState(() {
        if (hit == null) {
          selectionLabel = 'No triangle here';
          return;
        }
        selection = controller.scene.add(
          Line(
            LineGeometry(points: hit.triangle, closed: true),
            LineMaterial(
              color: const Color3(1, 1, 1),
              width: 2,
              depthTest: false,
            ),
            renderOrder: 1,
          ),
        );
        selectionLabel =
            '${hit.instanceIndex == null ? 'Skinned ribbon' : 'Instance ${hit.instanceIndex}'}'
            ' · triangle ${hit.triangleIndex} · ${hit.distance.toStringAsFixed(2)} units';
      });
    } on SceneException catch (error) {
      if (mounted && generation == pickGeneration) {
        setState(() => selectionLabel = error.issue.message);
      }
    }
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
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const ValueKey('Geometry projection'),
                  tooltip: controller.camera is OrthographicCamera
                      ? 'Use perspective camera'
                      : 'Use orthographic camera',
                  icon: Icon(
                    controller.camera is OrthographicCamera
                        ? Icons.view_in_ar
                        : Icons.crop_square,
                  ),
                  onPressed: () => setState(() {
                    clearSelection();
                    controller.camera = controller.camera is OrthographicCamera
                        ? demo.camera
                        : OrthographicCamera(position: demo.camera.position);
                  }),
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
                    clearSelection();
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(selectionLabel, style: const TextStyle(fontSize: 12)),
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
                if (controller.camera case OrthographicCamera camera) {
                  camera.verticalSize = math.max(
                    3.6,
                    4.2 / math.max(.1, aspect),
                  );
                }
                return SceneView(controller: controller, onPointer: select);
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
            onChanged: (value) => setState(() {
              clearSelection();
              change(value);
            }),
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
