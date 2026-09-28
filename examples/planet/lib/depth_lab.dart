import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'zero_state.dart';

void main() => runApp(const DepthLabApp());

enum DepthRange {
  surface('Surface', 1, .001),
  city('City', 1000, .001),
  horizon('Horizon', 100000, 1),
  orbit('Orbit', 10000000, 10);

  final String label;
  final double distance, gap;
  const DepthRange(this.label, this.distance, this.gap);
}

class DepthFixture {
  final scene = Scene()..background = const Color3(.018, .026, .04);
  final camera = PerspectiveCamera(
    position: const Vec3(6378137, 0, 0),
    target: const Vec3(6378137, 0, -1),
    near: .1,
    far: 1e9,
    depthStrategy: DepthStrategy.reversed,
  );
  late final Mesh farther, nearer;
  DepthRange range = DepthRange.horizon;
  DepthFixture() {
    final geometry = PlaneGeometry();
    farther = scene.add(
      Mesh(geometry, UnlitMaterial(color: const Color3(.65, .09, .055))),
    );
    nearer = scene.add(
      Mesh(geometry, UnlitMaterial(color: const Color3(.04, .65, .32))),
    );
    setRange(range);
  }
  void setRange(DepthRange value) {
    range = value;
    final distance = value.distance;
    farther.position = camera.position + Vec3(0, 0, -distance - value.gap);
    farther.scale = Vec3(distance * .8, distance * .8, 1);
    nearer.position = camera.position + Vec3(0, 0, -distance);
    nearer.scale = Vec3(distance * .65, distance * .65, 1);
  }
}

class DepthLabApp extends StatelessWidget {
  final DepthFixture? fixture;
  const DepthLabApp({super.key, this.fixture});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: DepthLab(fixture: fixture),
  );
}

class DepthLab extends StatefulWidget {
  final DepthFixture? fixture;
  const DepthLab({super.key, this.fixture});
  @override
  State<DepthLab> createState() => _DepthLabState();
}

class _DepthLabState extends State<DepthLab> {
  late final fixture = widget.fixture ?? DepthFixture();
  late final controller = SceneController(
    scene: fixture.scene,
    camera: fixture.camera,
    options: const EngineOptions(
      presentation: PresentationPolicy.requireNative,
    ),
    runtime: defaultTargetPlatform == TargetPlatform.android
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  );
  void change(VoidCallback update) {
    setState(update);
    controller.invalidate();
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text(
                      'Depth precision',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    DropdownButton<DepthStrategy>(
                      value: fixture.camera.depthStrategy,
                      items: [
                        for (final strategy in DepthStrategy.values)
                          DropdownMenuItem(
                            value: strategy,
                            child: Text(
                              strategy == DepthStrategy.reversed
                                  ? 'Reversed'
                                  : 'Standard',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          change(() => fixture.camera.depthStrategy = value);
                        }
                      },
                    ),
                  ],
                ),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final range in DepthRange.values)
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 40),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        onPressed: () => change(() => fixture.setRange(range)),
                        child: Text(range.label),
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('4×'),
                        Semantics(
                          label: 'Four-sample antialiasing',
                          child: Switch(
                            value:
                                fixture.scene.renderSettings.sampleCount == 4,
                            onChanged: (value) => change(
                              () => fixture.scene.renderSettings =
                                  RenderSettings(sampleCount: value ? 4 : 1),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              '${fixture.range.label}: ${fixture.range.distance.toStringAsFixed(0)} m away · ${fixture.range.gap} m gap. Green is nearer; coral is behind it.',
              style: const TextStyle(fontSize: 12),
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
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              'Clipping range: 0.1 m to 1 billion m',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
