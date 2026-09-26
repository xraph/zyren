import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_geospatial/flutter_geospatial.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'planet_scene.dart';

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

class ZeroState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ZeroState({super.key, required this.error, required this.onRetry});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.view_in_ar_outlined,
              size: 56,
              color: Color(0xff78dace),
            ),
            const SizedBox(height: 12),
            const Text(
              'The native renderer could not start',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text('$error'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry renderer'),
            ),
          ],
        ),
      ),
    ),
  );
}
