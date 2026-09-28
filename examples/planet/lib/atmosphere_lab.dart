import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'zero_state.dart';

void main() => runApp(const AtmosphereLabApp());

class AtmosphereFixture {
  final scene = Scene()
    ..renderSettings = RenderSettings(
      hdr: true,
      toneMapping: ToneMapping.aces,
      exposure: 3,
      spatialAntialiasing: SpatialAntialiasing.fxaa,
    );
  final camera = PerspectiveCamera(
    position: const Vec3(6379637, 0, 0),
    target: const Vec3(6379637, 0, 10000),
    up: const Vec3(1, 0, 0),
    near: 1,
    far: 1e9,
  );
  final sky = AtmospherePlugin(
    date: DateTime.utc(2026, 3, 20, 12),
    // Two-pixel points retain catalogue light through the display FXAA pass.
    appearance: AtmosphereAppearance(starPointSize: 2),
  );
  final sun = DirectionalLight(intensity: 2);
  AtmosphereFixture() {
    scene.add(
      Mesh(
        EllipsoidGeometry(longitudeSegments: 160, latitudeSegments: 80),
        StandardMaterial(baseColor: const Color3(.04, .12, .18), roughness: .9),
        name: 'Earth',
      ),
    );
    scene.add(sun);
    for (var i = 0; i < 4; i++) {
      scene
          .add(
            Mesh(
              BoxGeometry(width: 800, height: 800, depth: 800),
              StandardMaterial(
                baseColor: Color3(.35 + i * .1, .25, .12),
                roughness: .8,
              ),
            ),
          )
          .position = Geodetic.degrees(
        0,
        .06 + i * .06,
        400,
      ).toEcef();
    }
    setLight(12);
  }
  void setLight(int hour) {
    sun.direction = -CelestialDirections.at(
      DateTime.utc(2026, 3, 20, hour),
    ).sunECEF;
    scene.renderSettings = scene.renderSettings.copyWith(
      exposure: hour == 0 ? 1000 : 3,
    );
  }

  void horizon() {
    camera.position = const Vec3(6379637, 0, 0);
    camera.target = const Vec3(6379637, 0, 10000);
    camera.up = const Vec3(1, 0, 0);
  }

  void space() {
    camera.position = const Vec3(12500000, 0, 2400000);
    camera.target = Vec3.zero;
    camera.up = const Vec3(0, 0, 1);
  }
}

SceneController atmosphereLabController(AtmosphereFixture fixture) =>
    SceneController(
        scene: fixture.scene,
        camera: fixture.camera,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
        runtime: defaultTargetPlatform == TargetPlatform.android
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      )
      ..use(GeospatialPlugin())
      ..use(GlobeControlsPlugin())
      ..use(fixture.sky);

class AtmosphereLabApp extends StatelessWidget {
  const AtmosphereLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const AtmosphereLab(),
  );
}

class AtmosphereLab extends StatefulWidget {
  const AtmosphereLab({super.key});
  @override
  State<AtmosphereLab> createState() => _AtmosphereLabState();
}

class _AtmosphereLabState extends State<AtmosphereLab> {
  final fixture = AtmosphereFixture();
  late final controller = atmosphereLabController(fixture);
  int hour = 12;
  bool haze = true;
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: ValueListenableBuilder<SceneStatus>(
              valueListenable: controller.status,
              builder: (context, status, _) {
                final ready = status is SceneReady;
                return Wrap(
                  spacing: 8,
                  runSpacing: 0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      'Atmosphere',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SegmentedButton<int>(
                      segments: const [
                        ButtonSegment(value: 12, label: Text('Day')),
                        ButtonSegment(value: 18, label: Text('Dusk')),
                        ButtonSegment(value: 0, label: Text('Night')),
                      ],
                      selected: {hour},
                      showSelectedIcon: false,
                      onSelectionChanged: !ready
                          ? null
                          : (v) => setState(() {
                              hour = v.single;
                              fixture.sky.controller.date = DateTime.utc(
                                2026,
                                3,
                                20,
                                hour,
                              );
                              fixture.setLight(hour);
                              controller.invalidate();
                            }),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('Haze'),
                        Switch(
                          value: haze,
                          onChanged: !ready
                              ? null
                              : (v) => setState(() {
                                  haze = v;
                                  fixture.sky.controller.appearance = fixture
                                      .sky
                                      .controller
                                      .appearance
                                      .copyWith(haze: v);
                                }),
                        ),
                      ],
                    ),
                    TextButton(
                      onPressed: !ready
                          ? null
                          : () {
                              fixture.horizon();
                              controller.invalidate();
                            },
                      child: const Text('Horizon'),
                    ),
                    TextButton(
                      onPressed: !ready
                          ? null
                          : () {
                              fixture.space();
                              controller.invalidate();
                            },
                      child: const Text('Orbit'),
                    ),
                  ],
                );
              },
            ),
          ),
          Expanded(
            child: SceneView(
              controller: controller,
              resolutionScale: math.min(
                1,
                1 / MediaQuery.devicePixelRatioOf(context),
              ),
              errorBuilder: (context, issue, retry) =>
                  ZeroState(error: issue, onRetry: retry),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(6),
            child: Text(
              '20 March 2026 · UTC · Drag to navigate',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
