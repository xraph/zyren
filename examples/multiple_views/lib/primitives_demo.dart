import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

void main() => runApp(
  PrimitivesApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : const SceneRuntime.nativeMetal(),
  ),
);

class PrimitivesApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const PrimitivesApp({
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
    home: _Primitives(runtime: runtime, presentation: presentation),
  );
}

class _Primitives extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  const _Primitives({required this.runtime, required this.presentation});
  @override
  State<_Primitives> createState() => _PrimitivesState();
}

class _PrimitivesState extends State<_Primitives> {
  late final SceneController controller;
  late final Line edges;
  late final Points markers;
  SizeUnits units = SizeUnits.pixels;
  PointShape shape = PointShape.circle;
  double size = 6;
  bool far = false;
  LineMaterial lineMaterial() => LineMaterial(
    color: const Color3(.08, .65, 1),
    width: units == SizeUnits.pixels ? size : size / 60,
    widthUnits: units,
  );
  PointsMaterial pointMaterial() => PointsMaterial(
    color: const Color3(1, .5, .06),
    size: units == SizeUnits.pixels ? size * 2.5 : size / 24,
    sizeUnits: units,
    shape: shape,
  );
  void edit(VoidCallback action) => setState(() {
    action();
    edges.material = lineMaterial();
    markers.material = pointMaterial();
  });
  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      camera: PerspectiveCamera(position: const Vec3(3, 2, 5)),
      options: EngineOptions(presentation: widget.presentation),
    );
    controller.scene.background = const Color3(.025, .04, .065);
    final corners = [
      for (final z in [-1.0, 1.0])
        for (final y in [-1.0, 1.0])
          for (final x in [-1.0, 1.0]) Vec3(x, y, z),
    ];
    final pairs = <Vec3>[];
    for (var i = 0; i < 8; i++) {
      for (final bit in [1, 2, 4]) {
        if (i & bit == 0) pairs.addAll([corners[i], corners[i | bit]]);
      }
    }
    edges = controller.scene.add(
      Line(LineGeometry.segments(points: pairs), lineMaterial()),
    );
    markers = controller.scene.add(
      Points(PointGeometry(points: corners), pointMaterial()),
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
            const Text(
              'Native lines and points',
              style: TextStyle(fontSize: 22),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<SizeUnits>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: SizeUnits.pixels,
                      label: Text('Pixels'),
                    ),
                    ButtonSegment(value: SizeUnits.world, label: Text('World')),
                  ],
                  selected: {units},
                  onSelectionChanged: (value) =>
                      edit(() => units = value.single),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    far = !far;
                    controller.camera.position = far
                        ? const Vec3(6, 4, 10)
                        : const Vec3(3, 2, 5);
                  }),
                  child: Text(far ? 'Move closer' : 'Move away'),
                ),
                TextButton(
                  onPressed: () => edit(
                    () => shape = shape == PointShape.circle
                        ? PointShape.square
                        : PointShape.circle,
                  ),
                  child: Text(
                    shape == PointShape.circle ? 'Circles' : 'Squares',
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
                Text(
                  units == SizeUnits.pixels
                      ? '${size.round()} px'
                      : '${(size / 60).toStringAsFixed(2)} units',
                ),
                Expanded(
                  child: Slider(
                    value: size,
                    min: 1,
                    max: 12,
                    onChanged: (value) => edit(() => size = value),
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
