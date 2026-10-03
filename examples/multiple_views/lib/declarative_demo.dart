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
  bool spinning = true, showCube = true, orbit = true, effects = false;
  double size = 1;
  String pointerStatus = 'Point at the cube';
  SceneController? controller;
  final pipeline = ColorPipeline();
  final textureRequest = AssetRequest<TextureImage>(
    uri: Uri.parse('asset:///assets/images/corners.png'),
    loader: const TextureImageLoader(),
  );
  final modelRequest = Gltf.asset('assets/models/floating_triangle.gltf');

  Widget loading(BuildContext context, LoadProgress? progress) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(
          value: progress?.totalBytes == null || progress!.totalBytes == 0
              ? null
              : progress.completedBytes / progress.totalBytes!,
        ),
        const SizedBox(height: 4),
        Text(
          'Loading bundled asset${progress == null ? '' : ': ${progress.stage.name}'}',
        ),
      ],
    ),
  );

  Widget loadError(
    BuildContext context,
    Object error,
    StackTrace stack,
    VoidCallback retry,
  ) => ZeroState(
    title: 'Asset could not load',
    message: '$error',
    actionLabel: 'Retry asset',
    onAction: retry,
  );

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
            const Text(
              'Drag the background to orbit. Select or drag the cube.',
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 0,
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
                FilterChip(
                  label: const Text('Orbit'),
                  selected: orbit,
                  onSelected: (value) => setState(() => orbit = value),
                ),
                FilterChip(
                  label: const Text('FXAA'),
                  selected: effects,
                  onSelected: (value) => setState(() => effects = value),
                ),
                SizedBox(
                  width: 150,
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
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SceneCanvas(
                  runtime: widget.runtime,
                  options: widget.options,
                  onCreated: (value) {
                    controller = value;
                    widget.onCreated?.call(value);
                  },
                  orbitControls: orbit,
                  configureOrbitControls: (controls) =>
                      controls.rotateSpeed = .7,
                  colorPipeline: pipeline,
                  background: const Color3(.025, .04, .06),
                  camera: const SceneCamera.perspective(
                    position: Vec3(0, 1.4, 6),
                  ),
                  onPointerMissed: (_) {
                    controller!.selection = null;
                    setState(() => pointerStatus = 'Background clicked');
                  },
                  children: [
                    const PointLightNode(
                      position: Vec3(-2, 3, 4),
                      intensity: 20,
                    ),
                    const HemisphereLightNode(intensity: .6),
                    PostProcessingNode(enabled: effects, antialias: true),
                    GroupNode(
                      name: 'primitives',
                      children: [
                        if (showCube)
                          SceneSelector<bool>(
                            select: (state) => state.selection?.name == 'cube',
                            builder: (context, selected, child) => MeshNode(
                              key: const ValueKey('cube'),
                              name: 'cube',
                              geometry: const SceneGeometry.box(),
                              position: const Vec3(-.8, 0, 0),
                              scale: Vec3(size, size, size),
                              material: SceneMaterial.standard(
                                color: selected
                                    ? const Color3(.3, .85, .65)
                                    : const Color3(.95, .45, .16),
                                roughness: .6,
                              ),
                              onClick: (event) {
                                event.stopPropagation();
                                controller!.selection = event.currentTarget;
                              },
                              onPointerEnter: (_) => setState(
                                () => pointerStatus = 'Cube hovered',
                              ),
                              onPointerLeave: (_) => setState(
                                () => pointerStatus = 'Point at the cube',
                              ),
                              onPointerDown: (event) {
                                event.capturePointer();
                                setState(() => pointerStatus = 'Cube captured');
                              },
                              onPointerMove: (event) {
                                if (event.captureIntersection != null) {
                                  setState(
                                    () => pointerStatus =
                                        'Dragging captured cube',
                                  );
                                }
                              },
                              onPointerUp: (event) {
                                event.releasePointer();
                                setState(
                                  () => pointerStatus = 'Capture released',
                                );
                              },
                              onFrame: spinning
                                  ? (mesh, time) =>
                                        mesh.rotateY(time.deltaSeconds * .6)
                                  : null,
                            ),
                          ),
                        InstancedMeshNode(
                          name: 'instances',
                          geometry: const SceneGeometry.sphere(radius: .18),
                          capacity: 3,
                          count: 3,
                          transforms: [
                            for (var i = 0; i < 3; i++)
                              Mat4.compose(
                                Vec3(-.6 + i * .6, -.95, 0),
                                Quat.identity,
                                const Vec3(1, 1, 1),
                              ),
                          ],
                          colors: const [
                            Color3(.2, .55, .95),
                            Color3(.8, .4, .9),
                            Color3(.9, .7, .2),
                          ],
                        ),
                      ],
                    ),
                  ],
                  overlay: Stack(
                    children: [
                      SceneAsset<TextureImage>(
                        request: textureRequest,
                        loadingBuilder: loading,
                        errorBuilder: loadError,
                        builder: (context, image) => MeshNode(
                          name: 'textured-sphere',
                          geometry: const SceneGeometry.sphere(radius: .5),
                          position: const Vec3(.8, 0, 0),
                          material: SceneMaterial.unlit(
                            colorMap: TextureMap(image: image),
                          ),
                        ),
                      ),
                      ModelNode(
                        request: modelRequest,
                        name: 'bundled-model',
                        position: const Vec3(.8, 1.2, 0),
                        scale: const Vec3(.6, .6, .6),
                        loadingBuilder: loading,
                        errorBuilder: loadError,
                        builder: (context, instance) => ModelAnimationNode(
                          instance: instance,
                          clipName: 'Float',
                          paused: !spinning,
                        ),
                      ),
                      Positioned(
                        left: 8,
                        top: 8,
                        child: IgnorePointer(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SceneSelector<String>(
                                select: (state) =>
                                    state.selection?.name ?? 'No selection',
                                builder: (_, value, _) => Text(
                                  value == 'cube' ? 'Cube selected' : value,
                                ),
                              ),
                              Text(pointerStatus),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
