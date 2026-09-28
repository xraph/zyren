import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';

void main() => runApp(
  ShaderLabApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : Platform.isMacOS || Platform.isIOS
        ? const SceneRuntime.nativeMetal()
        : const SceneRuntime(),
  ),
);

class ShaderLabApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final UnsupportedEffects unsupported;
  const ShaderLabApp({
    super.key,
    required this.runtime,
    this.presentation = PresentationPolicy.requireNative,
    this.unsupported = UnsupportedEffects.reject,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      visualDensity: VisualDensity.compact,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff60bbad),
        brightness: Brightness.dark,
      ),
      scaffoldBackgroundColor: const Color(0xff101722),
    ),
    home: ShaderLab(
      runtime: runtime,
      presentation: presentation,
      unsupported: unsupported,
    ),
  );
}

class ShaderLab extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final UnsupportedEffects unsupported;
  const ShaderLab({
    super.key,
    required this.runtime,
    required this.presentation,
    required this.unsupported,
  });
  @override
  State<ShaderLab> createState() => _ShaderLabState();
}

class _ShaderLabState extends State<ShaderLab> {
  late final SceneController controller;
  late final EffectsPlugin effects;
  late final List<Registration> gestures;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  double yaw = .55,
      pitch = .3,
      distance = 7,
      gestureDistance = 7,
      resolution = .75;
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      options: EngineOptions(presentation: widget.presentation),
    );
    effects = controller.use(EffectsPlugin(unsupported: widget.unsupported));
    controller.scene.background = const Color3(.025, .035, .06);
    for (final (x, color) in [
      (-1.5, const Color3(.85, .06, .035)),
      (0.0, const Color3(.045, .7, .22)),
      (1.5, const Color3(.06, .22, .95)),
    ]) {
      controller.scene.add(
        Mesh(BoxGeometry(), DiffuseMaterial(color: color))
          ..position = Vec3(x, 0, 0),
      );
    }
    gestures = [
      controller.input.registerGesture(SceneGesture.scale),
      controller.input.registerGesture(SceneGesture.scroll),
    ];
    updateCamera();
    subscription = controller.frameStats.listen((value) {
      if (mounted) {
        setState(() {
          stats = value;
        });
      }
    });
  }

  void updateCamera() {
    controller.camera.position =
        Vec3(
          math.sin(yaw) * math.cos(pitch),
          math.sin(pitch),
          math.cos(yaw) * math.cos(pitch),
        ) *
        distance;
  }

  void pointer(ScenePointerEvent event) {
    if (event.phase == ScenePointerPhase.scaleStart) gestureDistance = distance;
    if (event.phase == ScenePointerPhase.scaleUpdate) {
      yaw -= event.delta.x * .008;
      pitch = (pitch + event.delta.y * .008).clamp(-1.45, 1.45);
      distance = (gestureDistance / event.scale).clamp(3, 20);
      updateCamera();
    } else if (event.phase == ScenePointerPhase.scroll) {
      distance = (distance * math.exp((event.delta.y * .001).clamp(-2, 2)))
          .clamp(3, 20);
      updateCamera();
    }
  }

  void configure(EffectsOptions options) => setState(() {
    effects.options = options;
  });
  Widget slider(
    String name,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
  ) => SizedBox(
    width: 250,
    height: 44,
    child: Row(
      children: [
        SizedBox(width: 74, child: Text(name)),
        Expanded(
          child: Slider(
            key: ValueKey(name),
            value: value,
            min: min,
            max: max,
            label: value.toStringAsFixed(2),
            onChanged: onChanged,
            semanticFormatterCallback: (value) =>
                '$name ${value.toStringAsFixed(2)}',
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(value.toStringAsFixed(1), textAlign: TextAlign.end),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final options = effects.options, frame = stats;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: [
                  const Text(
                    'Shader lab',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Effects'),
                      Switch(
                        value: options.enabled,
                        onChanged: (v) =>
                            configure(options.copyWith(enabled: v)),
                      ),
                      IconButton(
                        tooltip: 'Reset effects and camera',
                        icon: const Icon(Icons.restart_alt),
                        onPressed: () {
                          configure(EffectsOptions());
                          yaw = .55;
                          pitch = .3;
                          distance = 7;
                          updateCamera();
                        },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Resolution  '),
                      DropdownButton<double>(
                        key: const ValueKey('resolution'),
                        value: resolution,
                        items: [
                          for (final r in [.5, .75, 1.0])
                            DropdownMenuItem(
                              value: r,
                              child: Text('${(r * 100).round()}%'),
                            ),
                        ],
                        onChanged: (r) {
                          if (r != null) {
                            setState(() {
                              resolution = r;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 16,
                children: [
                  slider(
                    'Exposure',
                    options.exposure,
                    -2,
                    2,
                    (v) => configure(options.copyWith(exposure: v)),
                  ),
                  slider(
                    'Saturation',
                    options.saturation,
                    0,
                    2,
                    (v) => configure(options.copyWith(saturation: v)),
                  ),
                  slider(
                    'Vignette',
                    options.vignette,
                    0,
                    1,
                    (v) => configure(options.copyWith(vignette: v)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SceneView(
                controller: controller,
                onPointer: pointer,
                resolutionScale: resolution,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Wrap(
                spacing: 12,
                children: [
                  const Text(
                    'Drag to orbit · Scroll or pinch to zoom',
                    style: TextStyle(fontSize: 12),
                  ),
                  if (frame != null)
                    Text(
                      '${frame.physicalSize.width} × ${frame.physicalSize.height} · ${frame.drawCalls} draws · '
                      '${effects.state.graphBuilds} graph builds',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(subscription?.cancel());
    for (final gesture in gestures) {
      gesture.dispose();
    }
    controller.dispose();
    super.dispose();
  }
}
