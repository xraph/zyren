import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_geospatial/flutter_geospatial.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'main.dart' show ZeroState;

void main() => runApp(const CameraLabApp());

class CameraLabApp extends StatelessWidget {
  const CameraLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: const CameraLab(),
  );
}

class CameraLab extends StatefulWidget {
  const CameraLab({super.key});
  @override
  State<CameraLab> createState() => _CameraLabState();
}

class _CameraLabState extends State<CameraLab> {
  late final SceneController controller;
  String location = 'Manhattan';
  double heading = -155, pitch = -35, roll = 0, distance = 3000;
  Group? calibration;
  late Geodetic coordinate;
  double viewportAspect = 1;
  bool get metal =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    controller = SceneController(
      camera: PerspectiveCamera(near: 1, far: 1e8),
      runtime: metal ? const SceneRuntime.nativeMetal() : const SceneRuntime(),
      options: EngineOptions(
        presentation: metal
            ? PresentationPolicy.requireNative
            : PresentationPolicy.readbackOnly,
      ),
    );
    controller.use(GeospatialPlugin());
    _select('Manhattan');
  }

  void _select(String name) {
    location = name;
    coordinate = name == 'Manhattan'
        ? Geodetic.degrees(-73.9709, 40.7589)
        : Geodetic.degrees(138.5973, 35.2138);
    heading = name == 'Manhattan' ? -155 : 71;
    pitch = name == 'Manhattan' ? -35 : -31;
    distance = name == 'Manhattan' ? 3000 : 7000;
    roll = 0;
    if (calibration case final previous?) controller.scene.remove(previous);
    calibration = createCalibration(coordinate);
    controller.scene.add(calibration!);
    _apply();
  }

  void _apply() => PointOfView(
    distance: distance,
    heading: Angle.degrees(heading),
    pitch: Angle.degrees(pitch),
    roll: Angle.degrees(roll),
  ).decompose(coordinate.toEcef()).applyTo(controller.camera);

  void _projection(bool orthographic) {
    final previous = controller.camera;
    controller.camera = orthographic
        ? OrthographicCamera(
            position: previous.position,
            target: previous.target,
            up: previous.up,
            near: 1,
            far: 1e8,
          )
        : PerspectiveCamera(
            position: previous.position,
            target: previous.target,
            up: previous.up,
            near: 1,
            far: 1e8,
          );
    _resizeProjection();
  }

  void _resizeProjection() {
    if (controller.camera case final OrthographicCamera camera) {
      final halfHeight = distance * math.tan(25 * math.pi / 180);
      final halfWidth = halfHeight * viewportAspect;
      camera.setFrustum(
        left: -halfWidth,
        right: halfWidth,
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

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> update,
  ) => SizedBox(
    width: 250,
    child: Row(
      children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(
          child: Slider(
            semanticFormatterCallback: (v) => '$label ${v.round()} degrees',
            value: value,
            min: min,
            max: max,
            onChanged: (value) => setState(() {
              update(value);
              _apply();
            }),
          ),
        ),
        SizedBox(
          width: 48,
          child: Text('${value.round()}°', textAlign: TextAlign.end),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Geospatial camera lab',
                  style: TextStyle(fontSize: 18),
                ),
                for (final name in ['Manhattan', 'Fuji'])
                  ChoiceChip(
                    label: Text('$name pose'),
                    selected: location == name,
                    onSelected: (_) => setState(() => _select(name)),
                    visualDensity: VisualDensity.compact,
                  ),
                FilterChip(
                  label: const Text('Orthographic'),
                  selected: controller.camera is OrthographicCamera,
                  onSelected: (value) => setState(() => _projection(value)),
                  visualDensity: VisualDensity.compact,
                ),
                Text(
                  '${distance.round()} m · ${metal ? 'Metal native view' : 'Native GPU readback'}',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Reference camera poses over local calibration geometry. East: red · North: green · Up: blue',
              style: TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth > 0 && constraints.maxHeight > 0) {
                  viewportAspect = constraints.maxWidth / constraints.maxHeight;
                  _resizeProjection();
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _slider('Heading', heading, -180, 180, (v) => heading = v),
                _slider('Pitch', pitch, -89, -1, (v) => pitch = v),
                _slider('Roll', roll, -180, 180, (v) => roll = v),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

Group createCalibration(Geodetic coordinate) {
  final frame = EastNorthUpFrame(coordinate), group = Group();
  group.position = frame.origin;
  Vec3 rotate(Vec3 local) =>
      frame.east * local.x + frame.north * local.y + frame.up * local.z;
  void box(Vec3 size, Vec3 offset, Color3 color) {
    final source = BoxGeometry(width: size.x, height: size.y, depth: size.z);
    final geometry = BufferGeometry(
      positions: [
        for (var i = 0; i < source.positions.length; i += 3)
          ...rotate(Vec3.array(source.positions, i) + offset).storage,
      ],
      normals: [
        for (var i = 0; i < source.normals.length; i += 3)
          ...rotate(Vec3.array(source.normals, i)).storage,
      ],
      indices: source.indices,
    );
    group.add(Mesh(geometry, UnlitMaterial(color: color)));
  }

  box(
    const Vec3(2600, 2200, 4),
    const Vec3(0, 0, -4),
    const Color3(.09, .12, .16),
  );
  for (var i = -4; i <= 4; i++) {
    box(
      const Vec3(2400, 3, 2),
      Vec3(0, i * 250, 0),
      const Color3(.22, .28, .33),
    );
    box(
      const Vec3(3, 2000, 2),
      Vec3(i * 250, 0, 0),
      const Color3(.22, .28, .33),
    );
  }
  box(
    const Vec3(600, 40, 40),
    const Vec3(300, 0, 24),
    const Color3(.9, .08, .04),
  );
  box(
    const Vec3(40, 600, 40),
    const Vec3(0, 300, 24),
    const Color3(.04, .8, .16),
  );
  box(
    const Vec3(40, 40, 600),
    const Vec3(0, 0, 304),
    const Color3(.05, .24, 1),
  );
  return group;
}
