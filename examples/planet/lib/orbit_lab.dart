import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'zero_state.dart';

void main() => runApp(const OrbitLabApp());

class OrbitLabApp extends StatelessWidget {
  final OrbitBehavior behavior;
  const OrbitLabApp({super.key, this.behavior = OrbitBehavior.stdlib236});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: OrbitLab(behavior: behavior),
  );
}

class OrbitLab extends StatefulWidget {
  final OrbitBehavior behavior;
  const OrbitLab({super.key, this.behavior = OrbitBehavior.stdlib236});
  @override
  State<OrbitLab> createState() => _OrbitLabState();
}

class _OrbitLabState extends State<OrbitLab> {
  late final SceneController controller;
  late final OrbitControlsPlugin orbit;
  bool damping = true, cursorZoom = true;
  double aspect = 1;
  bool get metal =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;
  bool get android => defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    final scene = Scene();
    scene.add(
      Mesh(
        BoxGeometry(width: 12, height: .1, depth: 12),
        DiffuseMaterial(color: const Color3(.13, .17, .22)),
      )..position = const Vec3(0, -.1, 0),
    );
    final boxes = [
      (const Vec3(-2, 1, 0), const Color3(.9, .1, .04)),
      (const Vec3(0, 1.5, 0), const Color3(.04, .8, .16)),
      (const Vec3(2, .5, 0), const Color3(.05, .24, 1)),
    ];
    for (final (position, color) in boxes) {
      scene.add(
        Mesh(
          BoxGeometry(width: 1.5, height: position.y * 2, depth: 1.5),
          DiffuseMaterial(color: color),
        )..position = position,
      );
    }
    controller = SceneController(
      scene: scene,
      camera: PerspectiveCamera(
        position: const Vec3(8, 7, 12),
        target: const Vec3(0, 1, 0),
        near: .1,
        far: 1000,
      ),
      runtime: metal
          ? const SceneRuntime.nativeMetal()
          : android
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime(),
      options: EngineOptions(
        presentation: metal || android
            ? PresentationPolicy.requireNative
            : PresentationPolicy.readbackOnly,
      ),
    );
    orbit = controller.use(
      OrbitControlsPlugin(
        behavior: widget.behavior,
        keyboard: true,
        configure: (controls) {
          controls.enableDamping = damping;
          controls.zoomToCursor = cursorZoom;
          controls.minDistance = 1;
          controls.maxDistance = 100;
          controls.minZoom = .1;
          controls.maxZoom = 20;
        },
      ),
    );
  }

  void _projection(bool orthographic) {
    final previous = controller.camera;
    controller.camera = orthographic
        ? OrthographicCamera(
            position: previous.position,
            target: previous.target,
            up: previous.up,
            near: .1,
            far: 1000,
          )
        : PerspectiveCamera(
            position: previous.position,
            target: previous.target,
            up: previous.up,
            near: .1,
            far: 1000,
          );
    _resize();
  }

  void _resize() {
    if (controller.camera case final OrthographicCamera camera) {
      const halfHeight = 7.5;
      camera.setFrustum(
        left: -halfHeight * aspect,
        right: halfHeight * aspect,
        bottom: -halfHeight,
        top: halfHeight,
      );
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Native orbit: ${widget.behavior == OrbitBehavior.three184 ? 'Three r184' : 'stdlib'}',
                  style: const TextStyle(fontSize: 18),
                ),
                FilterChip(
                  label: const Text('Orthographic'),
                  selected: controller.camera is OrthographicCamera,
                  onSelected: (value) => setState(() => _projection(value)),
                  visualDensity: VisualDensity.compact,
                ),
                FilterChip(
                  label: const Text('Damping'),
                  selected: damping,
                  onSelected: (value) => setState(() {
                    damping = value;
                    orbit.controls?.enableDamping = value;
                    controller.invalidate();
                  }),
                  visualDensity: VisualDensity.compact,
                ),
                FilterChip(
                  label: const Text('Cursor zoom'),
                  selected: cursorZoom,
                  onSelected: (value) => setState(() {
                    cursorZoom = value;
                    orbit.controls?.zoomToCursor = value;
                  }),
                  visualDensity: VisualDensity.compact,
                ),
                TextButton(
                  onPressed: () => orbit.controls?.reset(),
                  child: const Text('Reset view'),
                ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth > 0 && constraints.maxHeight > 0) {
                  aspect = constraints.maxWidth / constraints.maxHeight;
                  _resize();
                }
                return SceneView(
                  controller: controller,
                  errorBuilder: (context, issue, retry) =>
                      ZeroState(error: issue, onRetry: retry),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              'Drag: orbit · Right drag or Shift-drag: pan · Wheel or pinch: zoom · Click the scene, then use arrow keys to pan\n${metal
                  ? 'Metal native view'
                  : android
                  ? 'Vulkan native surface'
                  : 'Native GPU readback'} · Perspective and orthographic · Y-up',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
