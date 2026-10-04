import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'zero_state.dart';
import 'photorealistic_layout.dart';

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
    depthStrategy: DepthStrategy.reversed,
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
      child: PhotorealisticLayout(
        title: 'Atmosphere',
        scene: SceneView(
          controller: controller,
          resolutionScale: math.min(
            1,
            1 / MediaQuery.devicePixelRatioOf(context),
          ),
          errorBuilder: (context, issue, retry) =>
              RendererZeroState(error: issue, onRetry: retry),
        ),
        controls: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<SceneStatus>(
              valueListenable: controller.status,
              builder: (context, status, _) {
                final ready = status is SceneReady;
                return Wrap(
                  spacing: 8,
                  runSpacing: 0,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final time in const [
                      (12, 'Day'),
                      (18, 'Dusk'),
                      (0, 'Night'),
                    ])
                      ChoiceChip(
                        label: Text(time.$2),
                        selected: hour == time.$1,
                        onSelected: !ready
                            ? null
                            : (_) => setState(() {
                                hour = time.$1;
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
                    Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
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
          ],
        ),
        info: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '20 March 2026 · UTC · Drag to navigate · Scroll or pinch to zoom',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}
