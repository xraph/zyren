import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

void main() => runApp(
  MaterialSideApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  ),
);

class MaterialSideApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const MaterialSideApp({
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
    home: _Sides(runtime: runtime, presentation: presentation),
  );
}

class _Sides extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const _Sides({required this.runtime, required this.presentation});
  @override
  State<_Sides> createState() => _SidesState();
}

class _SidesState extends State<_Sides> {
  late final SceneController controller;
  late final Group group;
  late final Mesh plane;
  MaterialSide side = MaterialSide.front;
  bool behind = false, mirrored = false, lit = true;
  void update(VoidCallback edit) => setState(() {
    edit();
    group.scale = Vec3(mirrored ? -1 : 1, 1, 1);
    controller.camera.position = Vec3(0, 0, behind ? -5 : 5);
    controller.scene.lightDirection = Vec3(0, 0, behind ? -1 : 1);
    plane.material = lit
        ? DiffuseMaterial(color: const Color3(.04, .65, 1), side: side)
        : UnlitMaterial(color: const Color3(.04, .65, 1), side: side);
  });
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      camera: PerspectiveCamera(),
      options: EngineOptions(presentation: widget.presentation),
    );
    controller.scene
      ..background = const Color3(.025, .04, .065)
      ..ambient = 0
      ..lightDirection = const Vec3(0, 0, 1);
    // An asymmetric triangle makes mirroring visible without changing its facing.
    plane = Mesh(
      BufferGeometry(
        positions: [-1.6, -1.2, 0, 1.4, -1.2, 0, -.9, 1.3, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [0, 1, 2],
      ),
      DiffuseMaterial(color: const Color3(.04, .65, 1), side: side),
    );
    group = controller.scene.add(Group()..add(plane));
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
            const Text('Material sides', style: TextStyle(fontSize: 20)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<MaterialSide>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: MaterialSide.front,
                      label: Text('Front'),
                    ),
                    ButtonSegment(
                      value: MaterialSide.back,
                      label: Text('Back'),
                    ),
                    ButtonSegment(
                      value: MaterialSide.doubleSided,
                      label: Text('Both'),
                    ),
                  ],
                  selected: {side},
                  onSelectionChanged: (value) =>
                      update(() => side = value.single),
                ),
                TextButton(
                  onPressed: () => update(() => behind = !behind),
                  child: Text(behind ? 'View front' : 'View back'),
                ),
                TextButton(
                  onPressed: () => update(() => mirrored = !mirrored),
                  child: Text(mirrored ? 'Unmirror' : 'Mirror'),
                ),
                TextButton(
                  onPressed: () => update(() => lit = !lit),
                  child: Text(lit ? 'Unlit' : 'Lit'),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '${behind ? 'Back' : 'Front'} · ${mirrored ? 'Mirrored' : 'Normal'} · '
                '${side == MaterialSide.doubleSided || (side == MaterialSide.back) == behind ? 'visible' : 'culled'}',
              ),
            ),
            Expanded(child: SceneView(controller: controller)),
          ],
        ),
      ),
    ),
  );
}
