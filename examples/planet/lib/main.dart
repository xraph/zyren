import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'planet_scene.dart';
import 'zero_state.dart';

void main() => runApp(const PlanetApp());

class PlanetApp extends StatelessWidget {
  const PlanetApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff080e19),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff78dace),
        brightness: Brightness.dark,
      ),
    ),
    home: const PlanetPage(),
  );
}

class PlanetPage extends StatefulWidget {
  const PlanetPage({super.key});
  @override
  State<PlanetPage> createState() => _PlanetPageState();
}

class _PlanetPageState extends State<PlanetPage> {
  final geospatial = GeospatialPlugin();
  final orbit = GlobeOrbitPlugin();
  late final scene = createPlanet(geospatial.reference);
  final camera = PerspectiveCamera(
    position: const Vec3(22000000, 0, 0),
    up: Vec3(0, 0, 1),
    near: 100000,
    far: 200000000,
    fieldOfView: Angle.degrees(42),
  );
  String selected = 'Lagos';
  late final SceneController controller;
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      scene: scene,
      camera: camera,
      options: const EngineOptions(
        presentation: PresentationPolicy.readbackOnly,
      ),
    );
    controller.use(geospatial);
    controller.use(orbit);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void focus(String name) {
    final point = locations[name]!;
    setState(() {
      selected = name;
      orbit.focus(Geodetic.degrees(point.$1, point.$2));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.language, color: Color(0xff78dace)),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Native planet',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          'WGS84  /  ECEF',
                          style: TextStyle(
                            fontSize: 11,
                            color: Color(0xff9aaebc),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: orbit.rotating ? 'Pause rotation' : 'Rotate globe',
                    onPressed: () =>
                        setState(() => orbit.rotating = !orbit.rotating),
                    icon: Icon(orbit.rotating ? Icons.pause : Icons.play_arrow),
                  ),
                  IconButton(
                    tooltip: 'Reset camera',
                    onPressed: () => setState(orbit.reset),
                    icon: const Icon(Icons.restart_alt),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: SceneView(
                      controller: controller,
                      resolutionScale: math.min(
                        1,
                        2 / MediaQuery.devicePixelRatioOf(context),
                      ),
                      onPointer: (event) {
                        if (event.phase == ScenePointerPhase.scaleStart) {
                          setState(() => orbit.rotating = false);
                        }
                      },
                      errorBuilder: (context, issue, retry) =>
                          ZeroState(error: issue, onRetry: retry),
                    ),
                  ),
                  const Positioned(
                    left: 20,
                    top: 8,
                    child: IgnorePointer(
                      child: Text(
                        'ELLIPSOID + GEODETIC MARKERS',
                        style: TextStyle(
                          fontSize: 10,
                          letterSpacing: 1.7,
                          color: Color(0xff8ba6b7),
                        ),
                      ),
                    ),
                  ),
                  const Positioned(
                    left: 20,
                    bottom: 12,
                    child: IgnorePointer(
                      child: Text(
                        'Drag to orbit · Scroll or pinch to zoom',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xff8ba6b7),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: Color(0xff223140))),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final name in locations.keys)
                      ChoiceChip(
                        label: Text(name),
                        selected: selected == name,
                        onSelected: (_) => focus(name),
                        visualDensity: VisualDensity.compact,
                      ),
                    const Text(
                      'Native GPU · RGBA preview',
                      style: TextStyle(fontSize: 11, color: Color(0xff8ba6b7)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
