import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'studio_environment.dart';

void main() => runApp(const PhysicalLabApp());

class PhysicalLabApp extends StatelessWidget {
  const PhysicalLabApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
    home: const _PhysicalLab(),
  );
}

class _PhysicalLab extends StatefulWidget {
  const _PhysicalLab();
  @override
  State<_PhysicalLab> createState() => _PhysicalLabState();
}

class _PhysicalLabState extends State<_PhysicalLab> {
  late final SceneController controller;
  final temporal = TemporalAntialiasing(enabled: false);
  final effects = PostProcessing();
  late final Mesh coat, cloth, glass, swatch;
  late final RectAreaLight area;
  double roughness = .18, thickness = 1.2;
  bool areaEnabled = true,
      msaa = true,
      film = true,
      dispersion = true,
      shadows = true;
  String storage = 'Loading texture';
  FrameStats? stats;
  StreamSubscription<FrameStats>? subscription;
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : Platform.isMacOS || Platform.isIOS
          ? const SceneRuntime.nativeMetal()
          : const SceneRuntime(),
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
      camera: PerspectiveCamera(position: const Vec3(0, 0, 7)),
      colorPipeline: ColorPipeline(sampleCount: 4),
    );
    controller.use(OrbitControls());
    controller.use(EnvironmentLighting(image: studioEnvironment()));
    controller.use(temporal);
    controller.use(effects);
    final scene = controller.scene..background = const Color3(.015, .025, .045);
    final sphere = SphereGeometry(
      radius: .72,
      widthSegments: 48,
      heightSegments: 32,
    );
    coat = scene.add(
      Mesh(
        sphere,
        PhysicalMaterial(
          baseColor: const Color3(.08, .28, .7),
          roughness: .3,
          iridescence: 1,
          iridescenceThicknessMaximum: 350,
          clearcoat: .2,
          clearcoatRoughness: .08,
        ),
      )..position = const Vec3(-1.75, 0, 0),
    );
    cloth = scene.add(
      Mesh(
        sphere,
        PhysicalMaterial(
          baseColor: const Color3(.3, .03, .04),
          roughness: .7,
          sheenColor: const Color3(.8, .2, .1),
          sheenRoughness: .4,
        ),
      ),
    );
    glass = scene.add(
      Mesh(
        sphere,
        PhysicalMaterial(
          transmission: 1,
          roughness: roughness,
          thickness: thickness,
          ior: 1.5,
          dispersion: 5,
          attenuationColor: const Color3(.3, .8, .95),
          attenuationDistance: 3,
        ),
      )..position = const Vec3(1.75, 0, 0),
    );
    for (var i = 0; i < 12; i++) {
      scene.add(
        Mesh(
          PlaneGeometry(width: .6, height: 4),
          UnlitMaterial(
            color: i.isEven
                ? const Color3(.8, .6, .2)
                : const Color3(.035, .08, .14),
          ),
        )..position = Vec3((i - 5.5) * .6, 0, -1),
      );
    }
    coat.castShadow = true;
    cloth.castShadow = true;
    scene.add(
      Mesh(
          PlaneGeometry(width: 9, height: 6),
          StandardMaterial(
            baseColor: const Color3(.12, .14, .18),
            roughness: .8,
          ),
        )
        ..rotateX(-math.pi / 2)
        ..position = const Vec3(0, -.9, 0)
        ..receiveShadow = true,
    );
    swatch = scene.add(
      Mesh(PlaneGeometry(width: 1.2, height: .55), UnlitMaterial())
        ..position = const Vec3(0, 1.4, 0),
    );
    unawaited(loadTexture());
    area = scene.add(
      RectAreaLight(
          width: 3,
          height: 2,
          intensity: 4,
          shadow: AreaShadow(far: 20),
        )
        ..position = const Vec3(0, 2.5, 3)
        ..lookAt(Vec3.zero),
    );
    subscription = controller.frameStats.listen((value) {
      if (mounted) setState(() => stats = value);
    });
  }

  Future<void> loadTexture() async {
    try {
      final info = await controller.ready;
      final source = await rootBundle.load('assets/colors-uastc.ktx2');
      final image = await NativeTextureDecoder.forDevice(info.capabilities)
          .decode(
            source.buffer.asUint8List(
              source.offsetInBytes,
              source.lengthInBytes,
            ),
            encoding: TextureEncoding.ktx2Basis,
          );
      if (!mounted) return;
      swatch.material = UnlitMaterial(
        colorMap: TextureMap(image: TextureImage.fromData(image)),
      );
      setState(
        () => storage =
            '${image.descriptor.format.name} · ${image.descriptor.byteLength} B',
      );
      controller.invalidate();
    } catch (error) {
      if (mounted) setState(() => storage = 'Texture failed: $error');
    }
  }

  void updateGlass() {
    glass.material = (glass.material as PhysicalMaterial).copyWith(
      roughness: roughness,
      thickness: thickness,
      dispersion: dispersion ? 5 : 0,
    );
    controller.invalidate();
  }

  Widget slider(
    String title,
    double value,
    double max,
    void Function(double) onChanged,
    double availableWidth,
  ) {
    final narrow = availableWidth < 480;
    final label = Text(
      '$title ${value.toStringAsFixed(2)}',
      style: const TextStyle(fontSize: 12),
    );
    final control = Slider(
      key: ValueKey(title),
      value: value,
      max: max,
      onChanged: (v) => setState(() => onChanged(v)),
    );
    return SizedBox(
      width: narrow ? (availableWidth - 8) / 2 : 240,
      child: narrow
          ? Column(mainAxisSize: MainAxisSize.min, children: [label, control])
          : Row(
              children: [
                SizedBox(width: 90, child: label),
                Expanded(child: control),
              ],
            ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Physical materials'), toolbarHeight: 44),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 8,
              runSpacing: 0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                slider('Roughness', roughness, 1, (v) {
                  roughness = v;
                  updateGlass();
                }, constraints.maxWidth),
                slider('Thickness', thickness, 3, (v) {
                  thickness = v;
                  updateGlass();
                }, constraints.maxWidth),
                FilterChip(
                  label: const Text('Iridescence'),
                  selected: film,
                  onSelected: (v) => setState(() {
                    film = v;
                    coat.material = (coat.material as PhysicalMaterial)
                        .copyWith(iridescence: v ? 1 : 0);
                    controller.invalidate();
                  }),
                ),
                FilterChip(
                  label: const Text('Dispersion'),
                  selected: dispersion,
                  onSelected: (v) => setState(() {
                    dispersion = v;
                    updateGlass();
                  }),
                ),
                FilterChip(
                  label: const Text('Area shadows'),
                  selected: shadows,
                  onSelected: (v) => setState(() {
                    shadows = v;
                    area.shadow = v ? AreaShadow(far: 20) : null;
                    controller.invalidate();
                  }),
                ),
                FilterChip(
                  label: const Text('Area light'),
                  selected: areaEnabled,
                  onSelected: (v) => setState(() {
                    areaEnabled = v;
                    area.intensity = v ? 4 : 0;
                    controller.invalidate();
                  }),
                ),
                FilterChip(
                  label: const Text('4× MSAA'),
                  selected: msaa,
                  onSelected: (v) => setState(() {
                    msaa = v;
                    if (v) temporal.enabled = false;
                    controller.colorPipeline = ColorPipeline(
                      sampleCount: v ? 4 : 1,
                    );
                  }),
                ),
                FilterChip(
                  label: const Text('Temporal AA'),
                  selected: temporal.enabled,
                  onSelected: (v) => setState(() {
                    if (v) {
                      msaa = false;
                      controller.colorPipeline = ColorPipeline();
                    }
                    temporal.enabled = v;
                  }),
                ),
                FilterChip(
                  label: const Text('Bloom'),
                  selected: effects.bloom != null,
                  onSelected: (v) =>
                      setState(() => effects.bloom = v ? BloomOptions() : null),
                ),
              ],
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [Text('Thin film'), Text('Sheen'), Text('Glass')],
          ),
        ),
        Expanded(child: SceneView(controller: controller, resolutionScale: .5)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              stats == null
                  ? 'Preparing materials…'
                  : '$storage · ${stats!.drawCalls} draws · drag to orbit',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    unawaited(subscription?.cancel());
    controller.dispose();
    super.dispose();
  }
}
