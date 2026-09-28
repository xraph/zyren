import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d_inspector/gpu3d_inspector.dart';

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
  final orbit = OrbitControls();
  late final List<Mesh> meshes;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  bool enabled = true;
  double pan = 0;
  Size viewport = Size.zero;
  Mesh? selected;
  Bounds3? framedBounds;
  String? selectionError;
  late final Registration tapGesture;
  int pickGeneration = 0;

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
    controller.use(orbit);
    tapGesture = controller.input.registerGesture(SceneGesture.tap);
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

  Bounds3 boundsOf(Mesh mesh) => mesh.bounds.transformed(mesh.worldMatrix);

  void frame(Bounds3 bounds) {
    if (viewport.isEmpty) return;
    pickGeneration++;
    controller.camera.frameBounds(bounds, aspect: viewport.aspectRatio);
    framedBounds = bounds;
    pan = controller.camera.target.x.clamp(-30, 30);
  }

  Future<void> select(ScenePointerEvent event) async {
    if (event.phase == ScenePointerPhase.scaleStart ||
        event.phase == ScenePointerPhase.scroll) {
      framedBounds = null;
      pickGeneration++;
    }
    if (event.phase != ScenePointerPhase.tap) return;
    final generation = ++pickGeneration;
    try {
      final hit = await controller.pick(event.point);
      if (!mounted || generation != pickGeneration) return;
      setState(() {
        selected = hit?.object;
        selectionError = null;
      });
    } on SceneException catch (error) {
      if (mounted && generation == pickGeneration) {
        setState(() => selectionError = error.issue.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    endDrawer: Drawer(
      width: MediaQuery.sizeOf(context).width.clamp(0, 380),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Frame inspected box',
                  icon: const Icon(Icons.center_focus_strong),
                  onPressed: selected == null
                      ? null
                      : () => setState(() => frame(boundsOf(selected!))),
                ),
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Close inspector',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
            Expanded(
              child: SceneInspector(
                controller: controller,
                selectedObject: selected,
                onSelectionChanged: (object) => setState(() {
                  selected = object is Mesh ? object : null;
                  selectionError = null;
                }),
              ),
            ),
          ],
        ),
      ),
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Camera culling',
                    style: TextStyle(fontSize: 18),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  key: const ValueKey('Frame all'),
                  tooltip: 'Frame all boxes',
                  icon: const Icon(Icons.fit_screen),
                  onPressed: () => setState(
                    () => frame(
                      meshes.fold(
                        const Bounds3.empty(),
                        (bounds, mesh) => bounds.union(boundsOf(mesh)),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('Frame selection'),
                  tooltip: 'Frame selected box',
                  icon: const Icon(Icons.center_focus_strong),
                  onPressed: selected == null
                      ? null
                      : () => setState(() => frame(boundsOf(selected!))),
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
                    pickGeneration++;
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
                    if (framedBounds case final bounds?) frame(bounds);
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
                IconButton(
                  key: const ValueKey('Reset orbit'),
                  tooltip: 'Reset orbit',
                  icon: const Icon(Icons.restart_alt),
                  onPressed: controller.status.value is! SceneReady
                      ? null
                      : () => setState(() {
                          framedBounds = null;
                          pickGeneration++;
                          orbit.reset();
                          pan = controller.camera.target.x.clamp(-30, 30);
                        }),
                ),
                const Text('Pan'),
                Expanded(
                  child: Slider(
                    key: const ValueKey('Camera pan'),
                    value: pan,
                    min: -30,
                    max: 30,
                    onChanged: (value) => setState(() {
                      pickGeneration++;
                      framedBounds = null;
                      pan = value;
                      controller.camera =
                          controller.camera is OrthographicCamera
                          ? OrthographicCamera(
                              position: Vec3(value, 2, 8),
                              target: Vec3(value, 0, 0),
                              verticalSize: 6,
                            )
                          : PerspectiveCamera(
                              position: Vec3(value, 2, 8),
                              target: Vec3(value, 0, 0),
                            );
                    }),
                  ),
                ),
                SizedBox(
                  width: 38,
                  child: Text(pan.toStringAsFixed(1), textAlign: TextAlign.end),
                ),
                Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Inspect scene',
                    icon: const Icon(Icons.account_tree_outlined),
                    onPressed: () => Scaffold.of(context).openEndDrawer(),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (viewport != constraints.biggest) {
                  viewport = constraints.biggest;
                  if (framedBounds case final bounds?) frame(bounds);
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
                    : '${stats!.drawCalls} / ${meshes.length} color draws · ${stats!.uploadedBytes} B uploaded'
                          '${selectionError == null
                              ? selected == null
                                    ? ''
                                    : '\n${selected!.name} selected'
                              : '\n$selectionError'}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
