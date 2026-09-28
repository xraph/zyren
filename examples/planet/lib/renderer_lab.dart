import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:shader_lab/shader_lab.dart';
import 'zero_state.dart';

void main() => runApp(const RendererLabApp());

SceneController rendererLabController(RendererFixture fixture) =>
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
      ..use(RendererProfilePlugin())
      ..use(fixture.environment())
      ..use(ShaderLabPlugin());

class RendererLabApp extends StatelessWidget {
  const RendererLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const RendererLab(),
  );
}

class RendererLab extends StatefulWidget {
  const RendererLab({super.key});
  @override
  State<RendererLab> createState() => _RendererLabState();
}

class _RendererLabState extends State<RendererLab> {
  final fixture = RendererFixture();
  late final controller = rendererLabController(fixture)
    ..use(OrbitControlsPlugin(behavior: OrbitBehavior.three184));
  bool glow = true;
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
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Material lab',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Glow'),
                    ValueListenableBuilder<SceneStatus>(
                      valueListenable: controller.status,
                      builder: (context, status, _) => Switch(
                        value: glow,
                        onChanged: status is! SceneReady
                            ? null
                            : (value) => setState(() {
                                glow = value;
                                fixture.scene.renderSettings = fixture
                                    .scene
                                    .renderSettings
                                    .copyWith(
                                      bloom: value
                                          ? BloomSettings(intensity: .12)
                                          : null,
                                      clearBloom: !value,
                                    );
                              }),
                      ),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () {
                    fixture.camera.position = const Vec3(6, 5, 8);
                    fixture.camera.target = const Vec3(0, .3, 0);
                    controller.invalidate();
                  },
                  child: const Text('Reset view'),
                ),
              ],
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
            padding: EdgeInsets.all(8),
            child: Text(
              'Drag to orbit · Roughness increases from left to right',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    ),
  );
}
