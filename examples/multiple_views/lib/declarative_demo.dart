import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

void main() => runApp(const DeclarativeDemo());

class DeclarativeDemo extends StatelessWidget {
  final SceneRuntime? runtime;
  final EngineOptions options;
  final void Function(SceneController)? onCreated;
  const DeclarativeDemo({
    super.key,
    this.runtime,
    this.options = const EngineOptions(),
    this.onCreated,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      visualDensity: VisualDensity.compact,
      scaffoldBackgroundColor: const Color(0xff10151c),
    ),
    home: _DemoScene(
      runtime:
          runtime ??
          switch (defaultTargetPlatform) {
            TargetPlatform.macOS ||
            TargetPlatform.iOS => const SceneRuntime.nativeMetal(),
            TargetPlatform.android => const SceneRuntime.nativeAndroid(),
            _ => const SceneRuntime(),
          },
      options: options,
      onCreated: onCreated,
    ),
  );
}

class _DemoScene extends StatefulWidget {
  final SceneRuntime runtime;
  final EngineOptions options;
  final void Function(SceneController)? onCreated;
  const _DemoScene({
    required this.runtime,
    required this.options,
    this.onCreated,
  });
  @override
  State<_DemoScene> createState() => _DemoSceneState();
}

class _DemoSceneState extends State<_DemoScene> {
  bool spinning = true, showCube = true, selected = false;
  double size = 1;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Zyren · Scene widgets',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text('Drag to orbit. Tap the cube to change its material.'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => setState(() => spinning = !spinning),
                  icon: Icon(
                    spinning ? Icons.pause : Icons.play_arrow,
                    size: 18,
                  ),
                  label: Text(spinning ? 'Pause' : 'Animate'),
                ),
                OutlinedButton(
                  onPressed: () => setState(() => showCube = !showCube),
                  child: Text(showCube ? 'Remove cube' : 'Add cube'),
                ),
                SizedBox(
                  width: 160,
                  child: Row(
                    children: [
                      const Text('Size'),
                      Expanded(
                        child: Slider(
                          value: size,
                          min: .5,
                          max: 1.5,
                          onChanged: (value) => setState(() => size = value),
                        ),
                      ),
                    ],
                  ),
                ),
                Text(selected ? 'Cube selected' : 'No selection'),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SceneCanvas(
                  runtime: widget.runtime,
                  options: widget.options,
                  onCreated: widget.onCreated,
                  orbitControls: true,
                  background: const Color3(.025, .04, .06),
                  camera: const SceneCamera.perspective(
                    position: Vec3(0, 1.4, 6),
                  ),
                  children: [
                    GroupNode(
                      children: [
                        if (showCube)
                          MeshNode(
                            key: const ValueKey('cube'),
                            name: 'cube',
                            geometry: const SceneGeometry.box(),
                            position: const Vec3(-.8, 0, 0),
                            scale: Vec3(size, size, size),
                            material: SceneMaterial.unlit(
                              color: selected
                                  ? const Color3(.3, .85, .65)
                                  : const Color3(.95, .45, .16),
                            ),
                            onTap: (_) => setState(() => selected = !selected),
                            onFrame: spinning
                                ? (mesh, time) =>
                                      mesh.rotateY(time.deltaSeconds * .6)
                                : null,
                          ),
                        const MeshNode(
                          key: ValueKey('sphere'),
                          name: 'sphere',
                          geometry: SceneGeometry.sphere(radius: .55),
                          position: Vec3(.9, 0, 0),
                          material: SceneMaterial.unlit(
                            color: Color3(.2, .55, .95),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
