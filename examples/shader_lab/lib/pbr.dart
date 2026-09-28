import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

void main() => runApp(const PbrLabApp());

class PbrLabApp extends StatelessWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  const PbrLabApp({
    super.key,
    this.runtime,
    this.presentation = PresentationPolicy.requireNative,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: _PbrLab(
      runtime:
          runtime ??
          (Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : Platform.isIOS || Platform.isMacOS
              ? const SceneRuntime.nativeMetal()
              : const SceneRuntime()),
      presentation: presentation,
    ),
  );
}

class _PbrLab extends StatefulWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  const _PbrLab({this.runtime, required this.presentation});
  @override
  State<_PbrLab> createState() => _PbrLabState();
}

class _PbrLabState extends State<_PbrLab> {
  late final SceneController controller;
  late final DirectionalLight sun;
  late final Group grid;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  double intensity = 3, angle = .5;
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      options: EngineOptions(presentation: widget.presentation),
      camera: PerspectiveCamera(
        position: const Vec3(0, 0, 9),
        fieldOfView: 1.05,
      ),
    );
    controller.scene.background = const Color3(.012, .018, .028);
    grid = controller.scene.add(Group());
    final sphere = SphereGeometry(
      radius: .5,
      widthSegments: 40,
      heightSegments: 24,
    );
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 4; column++) {
        grid.add(
          Mesh(
            sphere,
            StandardMaterial(
              baseColor: const Color3(.85, .5, .12),
              metallic: row * .5,
              roughness: const [.1, .35, .65, 1.0][column],
            ),
          )..position = Vec3((column - 1.5) * 1.35, (1 - row) * 1.35, 0),
        );
      }
    }
    sun = controller.scene.add(DirectionalLight(intensity: intensity));
    sun.quaternion =
        Quat.axisAngle(const Vec3(0, 1, 0), angle) *
        Quat.axisAngle(const Vec3(1, 0, 0), -.4);
    controller.scene.add(
      PointLight(color: const Color3(.3, .5, 1), intensity: 4)
        ..position = const Vec3(-3, 1, 3),
    );
    subscription = controller.frameStats.listen((value) {
      if (mounted) setState(() => stats = value);
    });
  }

  Widget control(
    String label,
    double value,
    double max,
    ValueChanged<double> change,
  ) => SizedBox(
    width: 250,
    child: Row(
      children: [
        SizedBox(width: 58, child: Text(label)),
        Expanded(
          child: Slider(
            key: ValueKey(label),
            value: value,
            max: max,
            onChanged: change,
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'PBR · direct lights',
                style: TextStyle(fontSize: 18),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Roughness 0.1 → 1 across · Metallic 0 → 1 down',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 12,
              children: [
                control(
                  'Light',
                  intensity,
                  5,
                  (v) => setState(() {
                    intensity = v;
                    sun.intensity = v;
                  }),
                ),
                control(
                  'Angle',
                  angle,
                  math.pi * 2,
                  (v) => setState(() {
                    angle = v;
                    sun.quaternion =
                        Quat.axisAngle(const Vec3(0, 1, 0), v) *
                        Quat.axisAngle(const Vec3(1, 0, 0), -.4);
                  }),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: SceneView(controller: controller)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                stats == null
                    ? 'Preparing native view'
                    : '${stats!.drawCalls} draws · ${stats!.physicalSize.width}×${stats!.physicalSize.height}',
                style: const TextStyle(fontSize: 12),
              ),
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
