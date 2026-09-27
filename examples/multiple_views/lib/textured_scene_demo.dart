import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

void main() => runApp(
  TexturedSceneApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  ),
);

class TexturedSceneApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const TexturedSceneApp({
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
    home: _TextureScene(runtime: runtime, presentation: presentation),
  );
}

class _TextureScene extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const _TextureScene({required this.runtime, required this.presentation});
  @override
  State<_TextureScene> createState() => _TextureSceneState();
}

class _TextureSceneState extends State<_TextureScene> {
  late final SceneController controller;
  late final Mesh mesh;
  final image = TextureImage.rgba(
    width: 2,
    height: 2,
    pixels: Uint8List.fromList([
      255,
      64,
      32,
      255,
      32,
      220,
      120,
      255,
      32,
      100,
      255,
      255,
      255,
      230,
      80,
      255,
    ]),
  );
  var filter = TextureFilter.nearest;
  var wrap = TextureWrap.repeat;

  UnlitMaterial material() => UnlitMaterial(
    colorMap: TextureMap(
      image: image,
      sampler: SamplerDescriptor(
        wrapU: wrap,
        wrapV: wrap,
        minFilter: filter,
        magFilter: filter,
      ),
    ),
  );

  @override
  void initState() {
    super.initState();
    controller = SceneController(
      camera: PerspectiveCamera(position: const Vec3(0, 0, 4)),
      runtime: widget.runtime,
      options: EngineOptions(presentation: widget.presentation),
    );
    controller.scene.background = const Color3(.025, .04, .065);
    mesh = controller.scene.add(
      Mesh(
        BufferGeometry(
          positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
          normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: [0, 1, 2, 0, 2, 3],
          uv0: [0, 2, 2, 2, 2, 0, 0, 0],
        ),
        material(),
      ),
    )..rotateY(.25);
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
            const Text('Native textures', style: TextStyle(fontSize: 22)),
            const Text('2 × 2 sRGB image · UV repeat × 2 · opaque color'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<TextureFilter>(
                  segments: const [
                    ButtonSegment(
                      value: TextureFilter.nearest,
                      label: Text('Nearest'),
                    ),
                    ButtonSegment(
                      value: TextureFilter.linear,
                      label: Text('Linear'),
                    ),
                  ],
                  selected: {filter},
                  onSelectionChanged: (value) => setState(() {
                    filter = value.single;
                    mesh.material = material();
                  }),
                ),
                SegmentedButton<TextureWrap>(
                  segments: const [
                    ButtonSegment(
                      value: TextureWrap.repeat,
                      label: Text('Repeat'),
                    ),
                    ButtonSegment(
                      value: TextureWrap.clampToEdge,
                      label: Text('Clamp'),
                    ),
                    ButtonSegment(
                      value: TextureWrap.mirroredRepeat,
                      label: Text('Mirror'),
                    ),
                  ],
                  selected: {wrap},
                  onSelectionChanged: (value) => setState(() {
                    wrap = value.single;
                    mesh.material = material();
                  }),
                ),
                OutlinedButton(
                  onPressed: () => mesh.rotateY(.2),
                  child: const Text('Turn plane'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(child: SceneView(controller: controller)),
          ],
        ),
      ),
    ),
  );
}
