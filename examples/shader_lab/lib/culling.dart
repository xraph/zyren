import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

void main() => runApp(const CullingLabApp());

class CullingLabApp extends StatelessWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  const CullingLabApp({
    super.key,
    this.runtime,
    this.presentation = PresentationPolicy.requireNative,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: _CullingLab(
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

class _CullingLab extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const _CullingLab({required this.runtime, required this.presentation});
  @override
  State<_CullingLab> createState() => _CullingLabState();
}

class _CullingLabState extends State<_CullingLab> {
  late final SceneController controller;
  late final List<Mesh> meshes;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  bool enabled = true;
  double pan = 0;

  @override
  void initState() {
    super.initState();
    final scene = Scene()..background = const Color3(.025, .035, .055);
    final geometry = BoxGeometry();
    const palette = [
      Color3(.2, .8, .9),
      Color3(.9, .55, .2),
      Color3(.55, .4, .9),
    ];
    meshes = List.generate(
      61,
      (i) => scene.add(
        Mesh(
            geometry,
            DiffuseMaterial(color: palette[i % palette.length]),
            name: 'Box $i',
          )
          ..position = Vec3((i - 30) * 1.4, 0, 0)
          ..quaternion = Quat.axisAngle(const Vec3(0, 1, 0), i * .13),
      ),
    );
    controller = SceneController(
      runtime: widget.runtime,
      scene: scene,
      camera: PerspectiveCamera(position: const Vec3(0, 2, 8)),
      options: EngineOptions(presentation: widget.presentation),
    );
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
                  child: Text('Camera culling', style: TextStyle(fontSize: 18)),
                ),
                IconButton(
                  key: const ValueKey('Culling projection'),
                  tooltip: controller.camera is OrthographicCamera
                      ? 'Use perspective camera'
                      : 'Use orthographic camera',
                  icon: Icon(
                    controller.camera is OrthographicCamera
                        ? Icons.view_in_ar
                        : Icons.crop_square,
                  ),
                  onPressed: () => setState(() {
                    final old = controller.camera;
                    controller.camera = old is OrthographicCamera
                        ? PerspectiveCamera(
                            position: old.position,
                            target: old.target,
                          )
                        : OrthographicCamera(
                            position: old.position,
                            target: old.target,
                            verticalSize: 6,
                          );
                  }),
                ),
                IconButton(
                  key: const ValueKey('Culling enabled'),
                  tooltip: enabled
                      ? 'Disable frustum culling'
                      : 'Enable frustum culling',
                  icon: Icon(enabled ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() {
                    enabled = !enabled;
                    controller.update(() {
                      for (final mesh in meshes) {
                        mesh.frustumCulled = enabled;
                      }
                    });
                  }),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Text('Pan'),
                Expanded(
                  child: Slider(
                    key: const ValueKey('Camera pan'),
                    value: pan,
                    min: -30,
                    max: 30,
                    onChanged: (value) => setState(() {
                      pan = value;
                      controller.camera.position = Vec3(value, 2, 8);
                      controller.camera.target = Vec3(value, 0, 0);
                    }),
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(pan.toStringAsFixed(1), textAlign: TextAlign.end),
                ),
              ],
            ),
          ),
          Expanded(child: SceneView(controller: controller)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                stats == null
                    ? 'Preparing renderer'
                    : '${stats!.drawCalls} / ${meshes.length} color draws · ${stats!.uploadedBytes} B uploaded',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
