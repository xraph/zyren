import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

void main() => runApp(
  MaterialAlphaApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  ),
);

class MaterialAlphaApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const MaterialAlphaApp({
    super.key,
    required this.runtime,
    this.presentation = PresentationPolicy.requireNative,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff111823),
      visualDensity: VisualDensity.compact,
    ),
    home: _Materials(runtime: runtime, presentation: presentation),
  );
}

class _Materials extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const _Materials({required this.runtime, required this.presentation});
  @override
  State<_Materials> createState() => _MaterialsState();
}

class _MaterialsState extends State<_Materials> {
  late final SceneController controller;
  late final Mesh front;
  final image = TextureImage.rgba(
    width: 2,
    height: 2,
    pixels: Uint8List.fromList([
      255,
      70,
      20,
      255,
      255,
      70,
      20,
      0,
      255,
      70,
      20,
      0,
      255,
      70,
      20,
      255,
    ]),
    generateMipmaps: true,
    mipmapAlphaFilter: MipmapAlphaFilter.weighted,
  );
  MaterialAlphaMode mode = MaterialAlphaMode.blend;
  DepthWrite depthWrite = DepthWrite.automatic;
  double opacity = .65;
  bool ordered = false;
  UnlitMaterial material() => UnlitMaterial(
    colorMap: TextureMap(image: image),
    alphaMode: mode,
    opacity: opacity,
    alphaCutoff: .5,
    depthWrite: depthWrite,
  );
  void edit(VoidCallback action) => setState(() {
    action();
    front.material = material();
    front.renderOrder = ordered ? -1 : 0;
  });
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      camera: PerspectiveCamera(position: const Vec3(0, 0, 5)),
      options: EngineOptions(presentation: widget.presentation),
    );
    controller.scene.background = const Color3(.025, .04, .065);
    final plane = PlaneGeometry(
      width: 2,
      height: 2,
      indexFormat: IndexFormat.uint16,
    );
    front = controller.scene.add(Mesh(plane, material()))
      ..position = const Vec3(.35, .25, .5);
    controller.scene
        .add(
          Mesh(
            plane,
            UnlitMaterial(
              color: const Color3(.08, 1, .15),
              alphaMode: MaterialAlphaMode.blend,
              opacity: .6,
            ),
          ),
        )
        .position = const Vec3(
      -.35,
      -.05,
      0,
    );
    controller.scene
        .add(Mesh(plane, UnlitMaterial(color: const Color3(.06, .2, 1))))
        .position = const Vec3(
      0,
      -.3,
      -.5,
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Native materials', style: TextStyle(fontSize: 22)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<MaterialAlphaMode>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: MaterialAlphaMode.opaque,
                      label: Text('Opaque'),
                    ),
                    ButtonSegment(
                      value: MaterialAlphaMode.mask,
                      label: Text('Mask'),
                    ),
                    ButtonSegment(
                      value: MaterialAlphaMode.blend,
                      label: Text('Blend'),
                    ),
                  ],
                  selected: {mode},
                  onSelectionChanged: (v) => edit(() => mode = v.single),
                ),
                TextButton(
                  onPressed: () => edit(() => ordered = !ordered),
                  child: Text(ordered ? 'Front first' : 'Depth order'),
                ),
                TextButton(
                  onPressed: () => edit(
                    () => depthWrite = depthWrite == DepthWrite.automatic
                        ? DepthWrite.enabled
                        : DepthWrite.automatic,
                  ),
                  child: Text(
                    depthWrite == DepthWrite.automatic
                        ? 'Auto depth'
                        : 'Write depth',
                  ),
                ),
                TextButton(
                  onPressed: () => controller.scene.rotateY(.35),
                  child: const Text('Turn'),
                ),
              ],
            ),
            Row(
              children: [
                Text('Opacity ${(opacity * 100).round()}%'),
                Expanded(
                  child: Slider(
                    value: opacity,
                    onChanged: (value) => edit(() => opacity = value),
                  ),
                ),
              ],
            ),
            Expanded(child: SceneView(controller: controller)),
          ],
        ),
      ),
    ),
  );
}
