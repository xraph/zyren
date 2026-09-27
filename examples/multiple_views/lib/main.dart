import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

void main() => runApp(const MultipleViewsApp());

class MultipleViewsApp extends StatelessWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  const MultipleViewsApp({
    super.key,
    this.runtime,
    this.presentation = PresentationPolicy.readbackOnly,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: const Color(0xff111823),
      visualDensity: VisualDensity.compact,
    ),
    home: SharedSceneViews(runtime: runtime, presentation: presentation),
  );
}

class SharedSceneViews extends StatefulWidget {
  final SceneRuntime? runtime;
  final PresentationPolicy presentation;
  const SharedSceneViews({
    super.key,
    this.runtime,
    this.presentation = PresentationPolicy.readbackOnly,
  });
  @override
  State<SharedSceneViews> createState() => _SharedSceneViewsState();
}

class _SharedSceneViewsState extends State<SharedSceneViews> {
  final scene = Scene()..background = const Color3(.06, .09, .14);
  late final Mesh mesh;
  SceneController? left;
  late final SceneController right;
  SceneController controller(Vec3 position) => SceneController(
    scene: scene,
    camera: PerspectiveCamera(position: position),
    options: EngineOptions(presentation: widget.presentation),
    runtime: widget.runtime,
  );

  @override
  void initState() {
    super.initState();
    mesh =
        scene.add(
            Mesh(
              BoxGeometry(),
              UnlitMaterial(color: const Color3(.98, .5, .22)),
            ),
          )
          ..rotateY(.4)
          ..rotateX(.25);
    scene
        .add(
          Mesh(
            SphereGeometry(radius: .35),
            UnlitMaterial(color: const Color3(.23, .69, .96)),
          ),
        )
        .position = const Vec3(
      1,
      .2,
      0,
    );
    left = controller(const Vec3(0, 0, 4));
    right = controller(const Vec3(3, 2, 4));
  }

  @override
  void dispose() {
    left?.dispose();
    right.dispose();
    super.dispose();
  }

  Widget viewport(String label, SceneController value) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(label),
      ),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SceneView(key: ValueKey(value), controller: value),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'One scene. Two cameras.',
              style: TextStyle(fontSize: 24),
            ),
            const SizedBox(height: 4),
            Text(
              widget.presentation == PresentationPolicy.readbackOnly
                  ? 'Native GPU · RGBA readback presentation'
                  : 'Native Metal · Direct view presentation',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                FilledButton(
                  onPressed: () => mesh.rotateY(.35),
                  child: const Text('Turn mesh'),
                ),
                if (left != null)
                  OutlinedButton(
                    onPressed: () {
                      left!.camera.position += const Vec3(.25, 0, 0);
                    },
                    child: const Text('Move left camera'),
                  ),
                OutlinedButton(
                  onPressed: () {
                    right.camera.position += const Vec3(.25, 0, 0);
                  },
                  child: const Text('Move right camera'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    if (left == null) {
                      left = controller(const Vec3(0, 0, 4));
                    } else {
                      left!.dispose();
                      left = null;
                    }
                  }),
                  child: Text(
                    left == null ? 'Open left view' : 'Close left view',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final views = [
                    if (left != null)
                      Expanded(child: viewport('Camera A', left!)),
                    if (left != null) const SizedBox(width: 12, height: 12),
                    Expanded(child: viewport('Camera B', right)),
                  ];
                  return constraints.maxWidth < 600
                      ? Column(children: views)
                      : Row(children: views);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
