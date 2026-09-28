import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'instancing_scene.dart';

void main() => runApp(
  InstancingApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : Platform.isMacOS || Platform.isIOS
        ? const SceneRuntime.nativeMetal()
        : const SceneRuntime(),
  ),
);

class InstancingApp extends StatelessWidget {
  final SceneRuntime runtime;
  const InstancingApp({super.key, required this.runtime});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: _InstancingView(runtime: runtime),
  );
}

class _InstancingView extends StatefulWidget {
  final SceneRuntime runtime;
  const _InstancingView({required this.runtime});
  @override
  State<_InstancingView> createState() => _InstancingViewState();
}

class _InstancingViewState extends State<_InstancingView> {
  late final SceneController controller;
  late final InstancedMesh instances;
  late final List<Registration> gestures;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  double yaw = .4, pitch = .65, distance = 150, startDistance = 150;
  bool lifted = false;
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      options: EngineOptions(presentation: PresentationPolicy.requireNative),
    );
    instances = populateInstances(controller.scene);
    gestures = [
      controller.input.registerGesture(SceneGesture.scale),
      controller.input.registerGesture(SceneGesture.scroll),
    ];
    camera();
    subscription = controller.frameStats.listen((value) {
      if (mounted) setState(() => stats = value);
    });
  }

  void camera() {
    controller.camera.position =
        Vec3(
          math.sin(yaw) * math.cos(pitch),
          math.sin(pitch),
          math.cos(yaw) * math.cos(pitch),
        ) *
        distance;
    (controller.camera as PerspectiveCamera).far = 1000;
  }

  void pointer(ScenePointerEvent event) {
    if (event.phase == ScenePointerPhase.scaleStart) startDistance = distance;
    if (event.phase == ScenePointerPhase.scaleUpdate) {
      yaw -= event.delta.x * .006;
      pitch = (pitch + event.delta.y * .006).clamp(.1, 1.5);
      distance = (startDistance / event.scale).clamp(30, 220);
      camera();
    } else if (event.phase == ScenePointerPhase.scroll) {
      distance = (distance * math.exp((event.delta.y * .001).clamp(-2, 2)))
          .clamp(30, 220);
      camera();
    }
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    for (final gesture in gestures) {
      gesture.dispose();
    }
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final frame = stats;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                spacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Native instances',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  DropdownButton<int>(
                    key: const ValueKey('Instance count'),
                    value: instances.count,
                    items: [
                      for (final n in [100, 1000, 10000])
                        DropdownMenuItem(value: n, child: Text('$n copies')),
                    ],
                    onChanged: (n) {
                      if (n != null) setState(() => instances.count = n);
                    },
                  ),
                  TextButton(
                    key: const ValueKey('Move one instance'),
                    onPressed: () {
                      lifted = !lifted;
                      instances.setTransform(
                        0,
                        lifted
                            ? Mat4.compose(
                                const Vec3(-49.5, 12, -49.5),
                                Quat.identity,
                                Vec3.one,
                              )
                            : instanceTransform(0),
                      );
                    },
                    child: const Text('Move one'),
                  ),
                  TextButton(
                    key: const ValueKey('Rotate instances'),
                    onPressed: () => instances.rotateY(.15),
                    child: const Text('Rotate group'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                frame == null
                    ? 'Preparing native renderer'
                    : '${frame.drawCalls} draw · ${frame.triangles} triangles · ${frame.uploadedBytes} B uploaded · ${frame.readbackBytes} B readback',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            Expanded(
              child: SceneView(controller: controller, onPointer: pointer),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text(
                'Drag to orbit. Pinch or scroll to zoom.',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
