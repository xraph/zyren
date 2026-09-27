import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'zero_state.dart';

void main() => runApp(const PickingLabApp());

class PickingLabApp extends StatelessWidget {
  const PickingLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const PickingLab(),
  );
}

class PickingLab extends StatefulWidget {
  const PickingLab({super.key});
  @override
  State<PickingLab> createState() => _PickingLabState();
}

class _PickingLabState extends State<PickingLab> {
  late final SceneController controller;
  final pointers = <int, ViewportPoint>{};
  int? clickPointer;
  late final OrbitControlsPlugin orbit;
  final originals = <Mesh, DiffuseMaterial>{};
  final names = <Mesh, String>{};
  PickResult? selected;
  SceneIssue? pickError;
  double aspect = 1;
  int request = 0;
  final highlight = DiffuseMaterial(color: const Color3(1, .8, .12));

  @override
  void initState() {
    super.initState();
    final scene = Scene();
    for (final (name, geometry, position, color) in [
      (
        'Box',
        BoxGeometry(width: 1.6, height: 1.6, depth: 1.6),
        const Vec3(-2.2, 0, 0),
        const Color3(.9, .16, .08),
      ),
      (
        'Sphere',
        SphereGeometry(radius: .95),
        Vec3.zero,
        const Color3(.12, .72, .38),
      ),
      (
        'Panel',
        PlaneGeometry(width: 1.6, height: 2),
        const Vec3(2.2, 0, 0),
        const Color3(.12, .38, .95),
      ),
    ]) {
      final material = DiffuseMaterial(color: color);
      final mesh = Mesh(geometry, material)..position = position;
      originals[mesh] = material;
      names[mesh] = name;
      scene.add(mesh);
    }
    final metal =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final android = defaultTargetPlatform == TargetPlatform.android;
    controller = SceneController(
      scene: scene,
      camera: PerspectiveCamera(
        position: const Vec3(0, 2, 10),
        near: .1,
        far: 100,
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
      OrbitControlsPlugin(behavior: OrbitBehavior.three184),
    );
  }

  // Orbit owns the gesture arena. Observe the same raw stream and reject
  // movement, secondary buttons and multiple pointers before selecting.
  void _pointer(ScenePointerEvent event) {
    switch (event.phase) {
      case ScenePointerPhase.down:
        pointers[event.pointer] = event.point;
        clickPointer = pointers.length == 1 && event.buttons == 1
            ? event.pointer
            : null;
      case ScenePointerPhase.move:
        final start = pointers[event.pointer];
        if (start != null && clickPointer == event.pointer) {
          final dx = event.point.x - start.x, dy = event.point.y - start.y;
          if (dx * dx + dy * dy > 36) clickPointer = null;
        }
      case ScenePointerPhase.up:
        final click = clickPointer == event.pointer;
        pointers.remove(event.pointer);
        clickPointer = null;
        if (click) _pick(event.point);
      case ScenePointerPhase.cancel:
        pointers.remove(event.pointer);
        clickPointer = null;
      default:
        break;
    }
  }

  Future<void> _pick(ViewportPoint point) async {
    final currentRequest = ++request;
    try {
      final hit = await controller.pick(point);
      if (!mounted || currentRequest != request) return;
      setState(() {
        pickError = null;
        _select(hit);
      });
    } on SceneException catch (error) {
      if (mounted && currentRequest == request) {
        setState(() => pickError = error.issue);
      }
    }
  }

  void _select(PickResult? hit) {
    if (selected case final previous?) {
      previous.object.material = originals[previous.object]!;
    }
    selected = hit;
    if (hit != null) hit.object.material = highlight;
  }

  void _projection(bool orthographic) {
    final old = controller.camera;
    controller.camera = orthographic
        ? OrthographicCamera(
            position: old.position,
            target: old.target,
            up: old.up,
            near: .1,
            far: 100,
          )
        : PerspectiveCamera(
            position: old.position,
            target: old.target,
            up: old.up,
            near: .1,
            far: 100,
          );
    _resize();
  }

  void _resize() {
    if (controller.camera case final OrthographicCamera camera) {
      final halfHeight = 4.4 / (aspect < 1 ? aspect : 1);
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
    request++;

    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Surface picking', style: TextStyle(fontSize: 18)),
                FilterChip(
                  label: const Text('Orthographic'),
                  selected: controller.camera is OrthographicCamera,
                  onSelected: (value) => setState(() => _projection(value)),
                  visualDensity: VisualDensity.compact,
                ),
                TextButton(
                  onPressed: () => setState(() {
                    request++;
                    _select(null);
                    pickError = null;
                  }),
                  child: const Text('Clear selection'),
                ),
                TextButton(
                  onPressed: () => orbit.controls?.reset(),
                  child: const Text('Reset view'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                pickError != null
                    ? pickError!.message
                    : selected == null
                    ? 'Tap a surface to select it. Drag to orbit.'
                    : '${names[selected!.object]} · ${selected!.distance.toStringAsFixed(2)} units · triangle ${selected!.triangleIndex}\n'
                          'World ${selected!.point.x.toStringAsFixed(3)}, ${selected!.point.y.toStringAsFixed(3)}, ${selected!.point.z.toStringAsFixed(3)}',
                key: const ValueKey('pick-status'),
                style: const TextStyle(fontSize: 12),
              ),
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
                  onPointer: _pointer,
                  errorBuilder: (context, issue, retry) =>
                      ZeroState(error: issue, onRetry: retry),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
