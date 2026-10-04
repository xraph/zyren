import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'studio_environment.dart';
import 'probe_lighting.dart';

void main() => runApp(const PbrLabApp());

class PbrLabApp extends StatelessWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  final bool environmentLighting;
  final bool postProcessing;
  final bool proceduralGeometry;
  const PbrLabApp({
    super.key,
    this.runtime,
    this.presentation = PresentationPolicy.requireNative,
    this.environmentLighting = true,
    this.postProcessing = false,
    this.proceduralGeometry = false,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true),
    home: _PbrLab(
      runtime:
          runtime ??
          (Platform.isAndroid
              ? const SceneRuntime.nativeAndroid()
              : Platform.isIOS || Platform.isMacOS
              ? const SceneRuntime.nativeMetal()
              : const SceneRuntime()),
      presentation: presentation,
      environmentLighting: environmentLighting,
      postProcessing: postProcessing,
      proceduralGeometry: proceduralGeometry,
    ),
  );
}

class _PbrLab extends StatefulWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  final bool environmentLighting;
  final bool postProcessing;
  final bool proceduralGeometry;
  const _PbrLab({
    this.runtime,
    required this.presentation,
    required this.environmentLighting,
    this.postProcessing = false,
    this.proceduralGeometry = false,
  });
  @override
  State<_PbrLab> createState() => _PbrLabState();
}

class _PbrLabState extends State<_PbrLab> {
  late final SceneController controller;
  late final DirectionalLight sun;
  late final HemisphereLight hemisphere;
  late final EnvironmentLighting environment;
  late final ProbeLabLighting probeLighting;
  String controls = 'lights';
  late final Mesh glass;
  double glassRoughness = 0, dispersion = 0;

  void _applyGlass() {
    glass.material = PhysicalMaterial(
      transmission: 1,
      thickness: .7,
      roughness: glassRoughness,
      dispersion: dispersion,
      specularAntiAliasingVariance: specularAA ? .15 : 0,
    );
  }

  double environmentAngle = 0;
  late final List<TextureMap> maps = _makeMaps();
  final effects = PostProcessing(bloom: BloomOptions());
  final temporal = TemporalAntialiasing(enabled: false);
  int sampleCount = 1;
  bool textured = true, shadows = true, specularAA = true;
  double ambient = 1, exposure = 1;
  ToneMapping toneMapping = ToneMapping.acesFilmic;
  late final Group grid;
  StreamSubscription<FrameStats>? subscription;
  FrameStats? stats;
  double intensity = 3, angle = .5;
  @override
  void initState() {
    super.initState();
    sampleCount = widget.postProcessing ? 4 : 1;
    environment = EnvironmentLighting(
      image: widget.environmentLighting ? studioEnvironment() : null,
    );
    controller = SceneController(
      runtime: widget.runtime,
      colorPipeline: ColorPipeline(sampleCount: sampleCount),
      options: EngineOptions(presentation: widget.presentation),
      camera: PerspectiveCamera(
        position: const Vec3(0, 0, 9),
        fieldOfView: 1.05,
      ),
    );
    if (widget.environmentLighting) controller.use(environment);
    probeLighting = ProbeLabLighting(environment);
    controller.use(probeLighting);
    if (widget.postProcessing) {
      controller.use(effects);
      controller.use(temporal);
    }
    controller.scene.background = const Color3(.012, .018, .028);
    grid = controller.scene.add(Group());
    final sphere = SphereGeometry(
      radius: .5,
      widthSegments: 40,
      heightSegments: 24,
    );
    final shapes = widget.proceduralGeometry
        ? <BufferGeometry>[
            TorusGeometry(radius: .36, tube: .14),
            CapsuleGeometry(radius: .25, length: .5),
            CylinderGeometry(radiusTop: .35, radiusBottom: .45, height: .8),
            ConeGeometry(radius: .45, height: 1),
            LatheGeometry([
              const Vec2(.2, -.5),
              const Vec2(.4, -.2),
              const Vec2(.25, .2),
              const Vec2(.35, .5),
            ]),
            TubeGeometry(
              CubicBezierCurve3(
                const Vec3(-.4, -.4, 0),
                const Vec3(.4, -.4, 0),
                const Vec3(-.4, .4, 0),
                const Vec3(.4, .4, 0),
              ),
              radius: .1,
            ),
            CircleGeometry(radius: .5),
            RingGeometry(innerRadius: .25, outerRadius: .5),
          ]
        : [sphere];
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 4; column++) {
        grid.add(
          Mesh(
              shapes[(row * 4 + column) % shapes.length],
              StandardMaterial(
                baseColor: const Color3(.85, .5, .12),
                metallic: row * .5,
                roughness: const [.1, .35, .65, 1.0][column],
              ),
            )
            ..position = Vec3((column - 1.5) * 1.35, (1 - row) * 1.35, 0)
            ..castShadow = true
            ..receiveShadow = true,
        );
      }
    }
    controller.scene.add(
      Mesh(
          PlaneGeometry(width: 9, height: 7),
          StandardMaterial(
            baseColor: const Color3(.08, .1, .14),
            roughness: .9,
          ),
        )
        ..position = const Vec3(0, 0, -1)
        ..receiveShadow = true,
    );
    glass = controller.scene.add(
      Mesh(
          PlaneGeometry(width: 4, height: 4),
          PhysicalMaterial(transmission: 1),
        )
        ..position = const Vec3(.5, 0, 1)
        ..renderOrder = 1
        ..visible = false,
    );
    _applyGlass();
    _applyTextures();
    hemisphere = controller.scene.add(
      HemisphereLight(
        skyColor: const Color3(.5, .65, 1),
        groundColor: const Color3(.15, .1, .06),
        intensity: ambient,
      ),
    );
    sun = controller.scene.add(
      DirectionalLight(
        intensity: intensity,
        shadow: DirectionalShadow(distance: 20),
      ),
    );
    sun.quaternion =
        Quat.axisAngle(const Vec3(0, 1, 0), angle) *
        Quat.axisAngle(const Vec3(1, 0, 0), -.4);
    controller.scene.add(
      PointLight(color: const Color3(.3, .5, 1), intensity: 4)
        ..position = const Vec3(-3, 1, 3),
    );
    subscription = controller.frameStats.listen((value) {
      if (mounted) setState(() => stats = value);
    });
  }

  List<TextureMap> _makeMaps() {
    final base = <int>[],
        normal = <int>[],
        packed = <int>[],
        emission = <int>[];
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 32; x++) {
        final ridge = math.sin(x * math.pi / 4) * math.cos(y * math.pi / 4);
        final nx = ridge * .5,
            ny = math.cos(x * math.pi / 4) * math.sin(y * math.pi / 4) * .5;
        normal.addAll([
          ((nx + 1) * 127.5).round(),
          ((ny + 1) * 127.5).round(),
          ((math.sqrt(1 - nx * nx - ny * ny) + 1) * 127.5).round(),
          255,
        ]);
        final bright = (x ~/ 8 + y ~/ 8).isEven;
        base.addAll([for (var i = 0; i < 3; i++) bright ? 255 : 190, 255]);
        packed.addAll([bright ? 255 : 50, 128 + (x * 127 ~/ 31), 255, 255]);
        emission.addAll([x % 8 == 0 ? 255 : 0, y % 8 == 0 ? 255 : 0, 0, 255]);
      }
    }
    return [
      for (final (i, bytes) in [base, normal, packed, emission].indexed)
        TextureMap(
          image: TextureImage.rgba(
            width: 32,
            height: 32,
            pixels: Uint8List.fromList(bytes),
            format: i == 1 || i == 2
                ? TextureFormat.rgba8Unorm
                : TextureFormat.rgba8UnormSrgb,
            generateMipmaps: true,
          ),
          sampler: const SamplerDescriptor(
            wrapU: TextureWrap.repeat,
            wrapV: TextureWrap.repeat,
          ),
        ),
    ];
  }

  void _applyTextures() {
    for (final mesh in grid.children.whereType<Mesh>()) {
      mesh.material = (mesh.material as StandardMaterial).copyWith(
        specularAntiAliasingVariance: specularAA ? .15 : 0,
        baseColorMap: maps[0],
        normalMap: maps[1],
        metallicRoughnessMap: maps[2],
        occlusionMap: maps[2],
        emissiveMap: maps[3],
        emissive: textured
            ? const Color3(.03, .03, .03)
            : const Color3(0, 0, 0),
        clearBaseColorMap: !textured,
        clearNormalMap: !textured,
        clearMetallicRoughnessMap: !textured,
        clearOcclusionMap: !textured,
        clearEmissiveMap: !textured,
      );
    }
  }

  Widget control(
    String label,
    double width,
    double value,
    double max,
    ValueChanged<double> change,
  ) => SizedBox(
    width: width,
    child: Row(
      children: [
        SizedBox(width: 58, child: Text(label)),
        Expanded(
          child: Slider(
            key: ValueKey(label),
            value: value,
            max: max,
            onChanged: change,
          ),
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final controlWidth = ((constraints.maxWidth - 36) / 2).clamp(
        140.0,
        250.0,
      );
      return Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.proceduralGeometry ? 'Core geometry' : 'PBR',
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('SpecularAA'),
                      tooltip: specularAA
                          ? 'Disable specular AA'
                          : 'Enable specular AA',
                      isSelected: specularAA,
                      icon: const Icon(Icons.blur_off),
                      selectedIcon: const Icon(Icons.blur_on),
                      onPressed: () => setState(() {
                        specularAA = !specularAA;
                        _applyTextures();
                        _applyGlass();
                      }),
                    ),
                    IconButton(
                      key: const ValueKey('Shadows'),
                      tooltip: shadows ? 'Disable shadows' : 'Enable shadows',
                      isSelected: shadows,
                      icon: const Icon(Icons.wb_shade_outlined),
                      selectedIcon: const Icon(Icons.wb_shade),
                      onPressed: () => setState(() {
                        shadows = !shadows;
                        sun.shadow = shadows
                            ? DirectionalShadow(distance: 20)
                            : null;
                      }),
                    ),
                    SizedBox(
                      width: 160,
                      child: DropdownButton<String>(
                        isExpanded: true,
                        key: const ValueKey('LightingControls'),
                        value: controls,
                        items: const [
                          DropdownMenuItem(
                            value: 'lights',
                            child: Text('Lights'),
                          ),
                          DropdownMenuItem(
                            value: 'environment',
                            child: Text('Environment'),
                          ),
                          DropdownMenuItem(
                            value: 'probes',
                            child: Text('Local probes'),
                          ),
                          DropdownMenuItem(
                            value: 'transmission',
                            child: Text('Transmission'),
                          ),
                        ],
                        onChanged: (value) => setState(() {
                          controls = value!;
                          glass.visible = controls == 'transmission';
                        }),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 12,
                  children: [
                    if (controls == 'transmission')
                      FilterChip(
                        key: const ValueKey('GlassMSAA'),
                        label: const Text('4× MSAA'),
                        showCheckmark: false,
                        selected: sampleCount == 4,
                        onSelected: (value) => setState(() {
                          sampleCount = value ? 4 : 1;
                          if (value) temporal.enabled = false;
                          controller.colorPipeline = ColorPipeline(
                            toneMapping: toneMapping,
                            exposure: exposure,
                            sampleCount: sampleCount,
                          );
                        }),
                      ),
                    if (controls != 'transmission' && controls != 'probes')
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Textures'),
                          Switch(
                            key: const ValueKey('Textures'),
                            value: textured,
                            onChanged: (value) => setState(() {
                              textured = value;
                              _applyTextures();
                            }),
                          ),
                        ],
                      ),
                    if (controls != 'probes')
                      SizedBox(
                        width: controlWidth,
                        child: DropdownButton<ToneMapping>(
                          isExpanded: true,
                          key: const ValueKey('ToneMapping'),
                          value: toneMapping,
                          items: [
                            for (final entry in ToneMapping.values)
                              DropdownMenuItem(
                                value: entry,
                                child: Text(switch (entry) {
                                  ToneMapping.linear => 'Linear',
                                  ToneMapping.reinhard => 'Reinhard',
                                  ToneMapping.acesFilmic => 'ACES Filmic',
                                  ToneMapping.aces => 'ACES',
                                  ToneMapping.cineon => 'Cineon',
                                  ToneMapping.agx => 'AgX',
                                  ToneMapping.neutral => 'Neutral',
                                }),
                              ),
                          ],
                          onChanged: (value) => setState(() {
                            toneMapping = value!;
                            controller.colorPipeline = ColorPipeline(
                              toneMapping: toneMapping,
                              exposure: exposure,
                              sampleCount: sampleCount,
                            );
                          }),
                        ),
                      ),
                    if (controls != 'probes')
                      control(
                        'Exposure',
                        controlWidth,
                        exposure,
                        4,
                        (value) => setState(() {
                          exposure = value;
                          controller.colorPipeline = ColorPipeline(
                            toneMapping: toneMapping,
                            exposure: exposure,
                            sampleCount: sampleCount,
                          );
                        }),
                      ),
                    if (controls == 'probes') ...[
                      FilledButton.tonal(
                        key: const ValueKey('ProbeLeft'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: probeLighting.supported
                            ? () => setState(() => probeLighting.update(0))
                            : null,
                        child: const Text('Left'),
                      ),
                      FilledButton.tonal(
                        key: const ValueKey('ProbeRight'),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onPressed: probeLighting.supported
                            ? () => setState(() => probeLighting.update(1))
                            : null,
                        child: const Text('Right'),
                      ),
                      IconButton(
                        tooltip: 'Cancel capture',
                        onPressed: () => setState(probeLighting.cancel),
                        icon: const Icon(Icons.stop_circle_outlined),
                      ),
                      DropdownButton<int>(
                        value: probeLighting.faceSize,
                        items: [
                          for (final n in [16, 32, 64, 128, 256])
                            DropdownMenuItem(value: n, child: Text('$n px')),
                        ],
                        onChanged: (n) =>
                            setState(() => probeLighting.faceSize = n!),
                      ),
                      FilterChip(
                        label: const Text('Local'),
                        showCheckmark: false,
                        selected: probeLighting.enabled,
                        onSelected: (v) =>
                            setState(() => probeLighting.setEnabled(v)),
                      ),
                      Text(
                        probeLighting.error ??
                            (!probeLighting.supported
                                ? 'GPU capture unavailable'
                                : '${probeLighting.probes?.count ?? 0} saved · ${probeLighting.probes?.captureFaces ?? 0}/6 faces · ${probeLighting.probes?.completedJobs ?? 0} jobs · ${((probeLighting.probes?.storageBytes ?? 0) / 1024).toStringAsFixed(0)} KiB'),
                      ),
                    ] else if (controls == 'transmission') ...[
                      control(
                        'Rough',
                        controlWidth,
                        glassRoughness,
                        1,
                        (value) => setState(() {
                          glassRoughness = value;
                          _applyGlass();
                        }),
                      ),
                      control(
                        'Dispersion',
                        controlWidth,
                        dispersion,
                        5,
                        (value) => setState(() {
                          dispersion = value;
                          _applyGlass();
                        }),
                      ),
                    ] else if (controls == 'environment') ...[
                      control(
                        'Sky',
                        controlWidth,
                        environment.intensity,
                        4,
                        (value) =>
                            setState(() => environment.intensity = value),
                      ),
                      control(
                        'Rotation',
                        controlWidth,
                        environmentAngle,
                        math.pi * 2,
                        (value) => setState(() {
                          environmentAngle = value;
                          environment.rotation = Quat.axisAngle(
                            const Vec3(0, 1, 0),
                            value,
                          );
                        }),
                      ),
                    ] else ...[
                      control(
                        'Ambient',
                        controlWidth,
                        ambient,
                        3,
                        (value) => setState(() {
                          ambient = value;
                          hemisphere.intensity = value;
                        }),
                      ),
                      control(
                        'Light',
                        controlWidth,
                        intensity,
                        5,
                        (v) => setState(() {
                          intensity = v;
                          sun.intensity = v;
                        }),
                      ),
                      control(
                        'Angle',
                        controlWidth,
                        angle,
                        math.pi * 2,
                        (v) => setState(() {
                          angle = v;
                          sun.quaternion =
                              Quat.axisAngle(const Vec3(0, 1, 0), v) *
                              Quat.axisAngle(const Vec3(1, 0, 0), -.4);
                        }),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.postProcessing)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 8,
                    children: [
                      FilterChip(
                        label: const Text('4× MSAA'),
                        showCheckmark: false,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        selected: sampleCount == 4,
                        onSelected: (value) => setState(() {
                          sampleCount = value ? 4 : 1;
                          if (value) temporal.enabled = false;
                          controller.colorPipeline = ColorPipeline(
                            toneMapping: toneMapping,
                            exposure: exposure,
                            sampleCount: sampleCount,
                          );
                        }),
                      ),
                      FilterChip(
                        label: const Text('Temporal AA'),
                        showCheckmark: false,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        selected: temporal.enabled,
                        onSelected: (value) => setState(() {
                          if (value) sampleCount = 1;
                          controller.colorPipeline = ColorPipeline(
                            toneMapping: toneMapping,
                            exposure: exposure,
                            sampleCount: sampleCount,
                          );
                          temporal.enabled = value;
                        }),
                      ),
                      FilterChip(
                        label: const Text('Bloom'),
                        showCheckmark: false,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        selected: effects.bloom != null,
                        onSelected: (value) => setState(
                          () => effects.bloom = value ? BloomOptions() : null,
                        ),
                      ),
                      FilterChip(
                        label: const Text('Spatial AA'),
                        showCheckmark: false,
                        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                        selected: effects.antialias,
                        onSelected: (value) =>
                            setState(() => effects.antialias = value),
                      ),
                    ],
                  ),
                ),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    SceneView(
                      controller: controller,
                      resolutionScale: widget.postProcessing ? .5 : 1,
                    ),
                    Positioned(
                      top: 8,
                      left: 12,
                      right: 12,
                      child: IgnorePointer(
                        child: Text(
                          controls == 'transmission'
                              ? 'Filter: 1 smooth / 9 rough taps · dispersion: 3 paths'
                              : 'Roughness 0.1 → 1 across · Metallic 0 → 1 down',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    stats == null
                        ? 'Preparing native view'
                        : '${stats!.drawCalls} draws · ${stats!.physicalSize.width}×${stats!.physicalSize.height}'
                              '${controls == 'transmission' ? ' · scene ${stats!.profile?.passes['scene']?.drawCalls ?? '?'} / capture ${stats!.profile?.passes['transmission']?.drawCalls ?? '?'}' : ''}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  @override
  void dispose() {
    unawaited(subscription?.cancel());
    controller.dispose();
    super.dispose();
  }
}
