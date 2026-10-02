import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'zero_state.dart';

void main() => runApp(const NavigationLabApp());

class NavigationLabApp extends StatelessWidget {
  const NavigationLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const NavigationLab(),
  );
}

class NavigationLab extends StatefulWidget {
  const NavigationLab({super.key});
  @override
  State<NavigationLab> createState() => _NavigationLabState();
}

class _NavigationLabState extends State<NavigationLab>
    with SingleTickerProviderStateMixin {
  static const initialPosition = Vec3(16000000, 1800000, 2200000);
  late final SceneController controller;
  late final GlobeControlsPlugin navigation;
  late final CameraTransitionManager transitions;
  late final Ticker ticker;
  late final StreamSubscription<ScenePointerEvent> pointers;
  final starts = <int, ViewportPoint>{};
  int? clickPointer;
  Duration lastTick = Duration.zero;
  bool transitioning = false;
  String selection =
      'Tap the globe to inspect a location. Drag its surface to navigate.';
  double aspect = 4 / 3;
  int pickRequest = 0;

  @override
  void initState() {
    super.initState();
    final scene = Scene()..background = const Color3(.015, .022, .035);
    scene.add(
      Mesh(
        EllipsoidGeometry(longitudeSegments: 128, latitudeSegments: 64),
        DiffuseMaterial(color: const Color3(.12, .43, .65)),
        name: 'Earth',
      ),
    );
    for (final (lon, lat, name, color) in [
      (0.0, 0.0, 'Equator', const Color3(1, .65, .15)),
      (15.0, 15.0, 'North marker', const Color3(.2, .9, .5)),
      (-15.0, -10.0, 'South marker', const Color3(.9, .3, .3)),
    ]) {
      scene
          .add(
            Mesh(
              SphereGeometry(
                radius: 90000,
                widthSegments: 20,
                heightSegments: 12,
              ),
              DiffuseMaterial(color: color),
              name: name,
            ),
          )
          .position = Geodetic.degrees(
        lon,
        lat,
        90000,
      ).toEcef();
    }
    final perspective = PerspectiveCamera(
      position: initialPosition,
      up: const Vec3(0, 0, 1),
      near: 1,
      far: 1e9,
    );
    transitions = CameraTransitionManager(
      perspective,
      OrthographicCamera(
        left: -800,
        right: 800,
        top: 600,
        bottom: -600,
        near: 0,
        far: 1e9,
      ),
    )..duration = const Duration(milliseconds: 400);
    final metal =
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final android = defaultTargetPlatform == TargetPlatform.android;
    controller = SceneController(
      scene: scene,
      camera: perspective,
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
    controller.use(GeospatialPlugin());
    navigation = controller.use(
      GlobeControlsPlugin(
        configureGlobe: (controls) {
          controls.enableDamping = true;
          controls.enabled = !transitioning;
        },
      ),
    );
    pointers = controller.input.events.listen(_pointer);
    ticker = createTicker((elapsed) {
      final dt =
          (elapsed - lastTick).inMicroseconds / Duration.microsecondsPerSecond;
      lastTick = elapsed;
      transitions.update(dt.clamp(0, .064));
      controller.camera = transitions.camera;
      controller.invalidate();
      if (!transitions.needsUpdate) {
        ticker.stop();
        setState(() => transitioning = false);
        navigation.controls?.enabled = true;
      }
    });
  }

  void _pointer(ScenePointerEvent event) {
    if (transitioning) return;
    switch (event.phase) {
      case ScenePointerPhase.down:
        starts[event.pointer] = event.point;
        clickPointer = starts.length == 1 && event.buttons == 1
            ? event.pointer
            : null;
      case ScenePointerPhase.move:
        final start = starts[event.pointer];
        if (start != null && clickPointer == event.pointer) {
          final dx = event.point.x - start.x, dy = event.point.y - start.y;
          if (dx * dx + dy * dy > 36) clickPointer = null;
        }
      case ScenePointerPhase.up:
        final click = clickPointer == event.pointer;
        starts.remove(event.pointer);
        clickPointer = null;
        if (click) unawaited(_pick(event.point));
      case ScenePointerPhase.cancel:
        starts.clear();
        clickPointer = null;
      default:
        break;
    }
  }

  Future<void> _pick(ViewportPoint point) async {
    final request = ++pickRequest;
    try {
      final hit = await controller.pick(point);
      if (!mounted || request != pickRequest) return;
      setState(() {
        if (hit == null) {
          selection = 'No surface at this position.';
          return;
        }
        final location = Ellipsoid.wgs84.fromEcef(hit.point);
        selection =
            'Selected ${hit.object.name}: ${location.latitudeDegrees.toStringAsFixed(3)}°, ${location.longitudeDegrees.toStringAsFixed(3)}°';
      });
    } on SceneException catch (error) {
      if (mounted && request == pickRequest) {
        setState(() => selection = error.issue.message);
      }
    }
  }

  void _toggleProjection() {
    if (transitioning) return;
    transitions.fixedPoint = navigation.controls?.getPivotPoint() ?? Vec3.zero;
    transitions.syncCameras();
    setState(() => transitioning = true);
    navigation.controls?.enabled = false;
    starts.clear();
    clickPointer = null;
    transitions.toggle();
    lastTick = Duration.zero;
    ticker.start();
  }

  void _reset() {
    ticker.stop();
    transitioning = false;
    transitions.mode = CameraMode.perspective;
    final camera = transitions.perspectiveCamera;
    camera.position = initialPosition;
    camera.target = Vec3.zero;
    camera.up = const Vec3(0, 0, 1);
    camera.setClippingRange(1, 1e9);
    navigation.controls?.cancel();
    navigation.controls?.enabled = true;
    controller.camera = camera;
    controller.invalidate();
    setState(
      () => selection =
          'Tap the globe to inspect a location. Drag its surface to navigate.',
    );
  }

  @override
  void dispose() {
    pickRequest++;
    ticker.dispose();
    transitions.dispose();
    unawaited(pointers.cancel());
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
                const Text('Globe navigation', style: TextStyle(fontSize: 18)),
                TextButton(
                  onPressed: transitioning ? null : _toggleProjection,
                  child: Text(
                    transitions.mode == CameraMode.perspective
                        ? 'Orthographic'
                        : 'Perspective',
                  ),
                ),
                TextButton(
                  onPressed: transitioning ? null : _reset,
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
                selection,
                key: const ValueKey('navigation-selection'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final next = constraints.maxWidth / constraints.maxHeight;
                if (next.isFinite && next > 0 && next != aspect) {
                  aspect = next;
                  transitions.orthographicCamera.setFrustum(
                    left: -600 * aspect,
                    right: 600 * aspect,
                  );
                }
                return SceneView(
                  controller: controller,
                  errorBuilder: (context, issue, retry) =>
                      RendererZeroState(error: issue, onRetry: retry),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
