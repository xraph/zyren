import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final ImageDecoder decoder;
  const TexturedSceneApp({
    super.key,
    required this.runtime,
    this.decoder = const NativeImageDecoder(),
    this.presentation = PresentationPolicy.requireNative,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff111823),
      visualDensity: VisualDensity.compact,
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    ),
    home: _TextureScene(
      runtime: runtime,
      presentation: presentation,
      decoder: decoder,
    ),
  );
}

class _TextureScene extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final ImageDecoder decoder;
  const _TextureScene({
    required this.runtime,
    required this.presentation,
    required this.decoder,
  });
  @override
  State<_TextureScene> createState() => _TextureSceneState();
}

class _TextureSceneState extends State<_TextureScene> {
  late final SceneController controller;
  late final Mesh mesh;
  late final GeometrySnapshot original;
  bool deformed = false, mipmaps = true, denseUv = false;
  double uvOffset = 0;
  var image = TextureImage.rgba(
    width: 2,
    height: 2,
    generateMipmaps: true,
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
  String source = 'RGBA';
  String? loading, error;

  Future<void> load(String format) async {
    if (loading != null) return;
    setState(() {
      loading = format;
      error = null;
    });
    try {
      final asset = format == 'PNG' ? 'corners.png' : 'gray.jpg';
      final bytes = await rootBundle.load('assets/images/$asset');
      final decoded = await widget.decoder.decode(Uint8List.sublistView(bytes));
      if (!mounted) return;
      setState(() {
        image = TextureImage.fromImage(decoded, generateMipmaps: mipmaps);
        source = format;
        mesh.material = material();
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        error = '$format failed: $failure. Tap $format to retry.';
      });
    } finally {
      if (mounted) {
        setState(() {
          loading = null;
        });
      }
    }
  }

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
          dynamic: true,
          indexFormat: IndexFormat.uint16,
          positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0],
          normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: [0, 1, 2, 0, 2, 3],
          uv0: [0, 2, 2, 2, 2, 0, 0, 0],
        ),
        material(),
      ),
    )..rotateY(.25);
    original = mesh.geometry.capture();
  }

  void deform() => setState(() {
    deformed = !deformed;
    mesh.geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([deformed ? .4 : 1, 1, 0]),
      firstVertex: 2,
    );
  });

  void toggleMipmaps() => setState(() {
    mipmaps = !mipmaps;
    image = TextureImage.rgba(
      width: image.descriptor.width,
      height: image.descriptor.height,
      pixels: image.levels.first,
      format: image.descriptor.format,
      generateMipmaps: mipmaps,
    );
    mesh.material = material();
  });

  void shiftUv() => setState(() {
    uvOffset = (uvOffset + .25) % 2;
    updateUv();
  });

  void updateUv() {
    mesh.geometry.updateAttribute(
      VertexSemantic.uv0,
      Float32List.fromList([
        for (var i = 0; i < original.uv0!.length; i++)
          original.uv0![i] * (denseUv ? 128 : 1) + (i.isEven ? uvOffset : 0),
      ]),
    );
  }

  void reset() => setState(() {
    deformed = false;
    denseUv = false;
    uvOffset = 0;
    mesh.geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList(original.positions),
    );
    mesh.geometry.updateAttribute(
      VertexSemantic.uv0,
      Float32List.fromList(original.uv0!),
    );
  });

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
            const Text('Native mesh', style: TextStyle(fontSize: 22)),
            Text(
              '$source ${image.descriptor.width}×${image.descriptor.height} · ${image.descriptor.mipLevels} mips',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<TextureFilter>(
                  showSelectedIcon: false,
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
                  showSelectedIcon: false,
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
                  child: const Text('Turn'),
                ),
                TextButton(onPressed: deform, child: const Text('Deform')),
                TextButton(onPressed: reset, child: const Text('Reset')),
                TextButton(onPressed: shiftUv, child: const Text('Shift UV')),
                TextButton(
                  onPressed: toggleMipmaps,
                  child: Text(mipmaps ? 'Mips on' : 'Mips off'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    denseUv = !denseUv;
                    updateUv();
                  }),
                  child: Text(denseUv ? 'Wide UV' : 'Dense UV'),
                ),
                for (final format in ['PNG', 'JPEG'])
                  TextButton(
                    onPressed: loading == null ? () => load(format) : null,
                    child: Text(format),
                  ),
                if (loading != null) Text('Decoding $loading…'),
              ],
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.orange)),
            const SizedBox(height: 4),
            Expanded(child: SceneView(controller: controller)),
          ],
        ),
      ),
    ),
  );
}
