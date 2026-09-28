import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'model_bounds.dart';
import 'widgets/zero_state.dart';

void main() => runApp(
  ModelViewerApp(
    runtime: Platform.isAndroid
        ? const SceneRuntime.nativeAndroid()
        : Platform.isMacOS || Platform.isIOS
        ? const SceneRuntime.nativeMetal()
        : const SceneRuntime(),
  ),
);

class ModelViewerApp extends StatelessWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final bool autoplayAnimations;
  const ModelViewerApp({
    super.key,
    required this.runtime,
    this.presentation = PresentationPolicy.requireNative,
    this.autoplayAnimations = true,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true).copyWith(
      visualDensity: VisualDensity.compact,
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(48, 40),
        ),
      ),
      scaffoldBackgroundColor: const Color(0xff101722),
    ),
    home: ModelViewer(
      runtime: runtime,
      presentation: presentation,
      autoplayAnimations: autoplayAnimations,
    ),
  );
}

class ModelViewer extends StatefulWidget {
  final SceneRuntime runtime;
  final PresentationPolicy presentation;
  final bool autoplayAnimations;
  const ModelViewer({
    super.key,
    required this.runtime,
    this.presentation = PresentationPolicy.requireNative,
    this.autoplayAnimations = true,
  });
  @override
  State<ModelViewer> createState() => _ModelViewerState();
}

class _ModelViewerState extends State<ModelViewer> {
  late final SceneController controller;
  late final List<Registration> gestures;
  final address = TextEditingController();
  LoadTask<ModelAsset>? task;
  StreamSubscription<LoadProgress>? progress;
  ModelAsset? model;
  ModelInstance? instance;
  Group? studio;
  late final AnimationSystem animations;
  Registration? animationRegistration;
  AnimationAction? action;
  int selectedAnimation = 0;
  StreamSubscription<FrameStats>? frames;
  AssetRequest<ModelAsset>? lastRequest;
  int generation = 0, selectedScene = 0;
  bool busy = false, diagnostic = false;
  String status = 'Choose a model', error = '';
  List<String> names = const [];
  Vec3 target = Vec3.zero;
  double radius = 1, distance = 5, yaw = .65, pitch = .35, gestureDistance = 5;

  @override
  void initState() {
    super.initState();
    controller = SceneController(
      runtime: widget.runtime,
      options: EngineOptions(presentation: widget.presentation),
    );
    animations = controller.use(AnimationSystem());
    frames = controller.frameStats.listen((_) {
      if (mounted && action != null) setState(() {});
    });
    controller.scene.background = const Color3(.025, .04, .065);
    gestures = [
      controller.input.registerGesture(SceneGesture.scale),
      controller.input.registerGesture(SceneGesture.scroll),
    ];
    camera();
    unawaited(
      load(
        bundle(
          const String.fromEnvironment(
            'GPU3D_MODEL',
            defaultValue: 'assembly.glb',
          ),
        ),
      ),
    );
  }

  GltfOptions get options => GltfOptions(
    materialMode: diagnostic
        ? GltfMaterialMode.unlitDiagnostic
        : GltfMaterialMode.standard,
  );
  AssetRequest<ModelAsset> bundle(String file) =>
      Gltf.asset('assets/models/$file', options: options);
  void camera() {
    controller.camera.target = target;
    controller.camera.position =
        target +
        Vec3(
              math.sin(yaw) * math.cos(pitch),
              math.sin(pitch),
              math.cos(yaw) * math.cos(pitch),
            ) *
            distance;
    final perspective = controller.camera as PerspectiveCamera;
    perspective.near = math.max(radius / 1000, .000001);
    perspective.far = math.max(distance + radius * 10, 10);
  }

  void resetCamera() {
    yaw = .65;
    pitch = .35;
    distance = radius * 3.8;
    camera();
  }

  void pointer(ScenePointerEvent event) {
    if (event.phase == ScenePointerPhase.scaleStart) gestureDistance = distance;
    if (event.phase == ScenePointerPhase.scaleUpdate) {
      yaw -= event.delta.x * .008;
      pitch = (pitch + event.delta.y * .008).clamp(-1.45, 1.45);
      distance = (gestureDistance / event.scale).clamp(
        radius * 1.1,
        radius * 100,
      );
      camera();
    } else if (event.phase == ScenePointerPhase.scroll) {
      distance = (distance * math.exp((event.delta.y * .001).clamp(-2, 2)))
          .clamp(radius * 1.1, radius * 100);
      camera();
    }
  }

  bool stale(int ticket) => !mounted || ticket != generation;
  Future<void> load(AssetRequest<ModelAsset> request) async {
    final ticket = ++generation;
    task?.cancel();
    unawaited(progress?.cancel());
    setState(() {
      busy = true;
      error = '';
      status = 'Fetching model';
      lastRequest = request;
    });
    ModelAsset? acquired;
    try {
      final loading = task = controller.assets.load(request);
      progress = loading.progress.listen((value) {
        if (stale(ticket)) return;
        setState(() {
          status =
              '${value.stage.name} · ${value.completedBytes} bytes'
              '${value.totalBytes == null ? '' : ' / ${value.totalBytes}'}';
        });
      });
      acquired = await loading.result;
      if (stale(ticket)) return;
      final sceneIndex = acquired.defaultSceneIndex ?? 0;
      final next = acquired.instantiate(sceneIndex: sceneIndex);
      final bounds = await modelBounds(next, () => stale(ticket));
      if (stale(ticket)) return;
      if (instance case final previous?) controller.scene.remove(previous);
      if (model case final previous?) controller.assets.release(previous);
      configureAnimation(next);
      configureLighting(next);
      controller.scene.add(next);
      setState(() {
        model = acquired;
        instance = next;
        selectedScene = sceneIndex;
        names = objectNames(next);
        busy = false;
        status = '${names.length} objects';
      });
      acquired = null;
      target = bounds.center;
      radius = bounds.radius;
      resetCamera();
    } on LoadCancelled {
      if (!stale(ticket)) {
        setState(() {
          busy = false;
          status = 'Cancelled';
        });
      }
    } catch (failure) {
      if (!stale(ticket)) {
        setState(() {
          busy = false;
          status = 'Load failed';
          error = failure is SceneException
              ? failure.issue.message
              : failure.toString();
          if (failure is AssetLoadException && failure.fieldPath != null) {
            error = '${failure.fieldPath}: $error';
          }
        });
      }
    } finally {
      if (acquired != null) controller.assets.release(acquired);
      if (!stale(ticket)) {
        await progress?.cancel();
        progress = null;
        task = null;
      }
    }
  }

  void configureAnimation(ModelInstance next) {
    animationRegistration?.dispose();
    instance?.mixer.stopAll();
    action = null;
    animationRegistration = null;
    selectedAnimation = next.animations.indexWhere(
      (clip) => clip.tracks.isNotEmpty,
    );
    if (selectedAnimation < 0) return;
    animationRegistration = animations.add(next.mixer);
    action = next.mixer.play(next.animations[selectedAnimation]);
    if (!widget.autoplayAnimations) action!.pause();
  }

  void selectAnimation(int? index) {
    if (index == null || instance == null) return;
    final playing = action?.isPlaying ?? false;
    instance!.mixer.stopAll();
    setState(() {
      selectedAnimation = index;
      action = instance!.mixer.play(instance!.animations[index]);
      if (!playing) action!.pause();
    });
  }

  Widget animationControls() => Row(
    children: [
      SizedBox(
        width: 100,
        child: DropdownButton<int>(
          key: const ValueKey('Animation clip'),
          isExpanded: true,
          value: selectedAnimation,
          onChanged: selectAnimation,
          items: [
            for (var i = 0; i < instance!.animations.length; i++)
              if (instance!.animations[i].tracks.isNotEmpty)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    instance!.animations[i].name ?? 'Clip ${i + 1}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
          ],
        ),
      ),
      IconButton(
        key: const ValueKey('Animation playback'),
        tooltip: action!.isPlaying ? 'Pause animation' : 'Play animation',
        onPressed: () => setState(() {
          if (action!.isPlaying) {
            action!.pause();
          } else {
            action!.resume();
          }
        }),
        icon: Icon(action!.isPlaying ? Icons.pause : Icons.play_arrow),
      ),
      Expanded(
        child: Slider(
          key: const ValueKey('Animation playhead'),
          value: action!.timeSeconds,
          max: math.max(action!.clip.durationSeconds, .001),
          label: '${action!.timeSeconds.toStringAsFixed(1)} s',
          onChanged: (value) => setState(
            () => action!.seek(Duration(microseconds: (value * 1e6).round())),
          ),
        ),
      ),
      IconButton(
        tooltip: 'Restart animation',
        onPressed: () => setState(() => action!.seek(Duration.zero)),
        icon: const Icon(Icons.replay),
      ),
    ],
  );

  void configureLighting(Group root) {
    var hasPbr = false, hasLights = false;
    final pending = <Object3D>[root];
    while (pending.isNotEmpty) {
      final object = pending.removeLast();
      hasPbr |= object is Mesh && object.material is StandardMaterial;
      hasLights |= object is Light;
      pending.addAll(object.children);
    }
    studio = null;
    if (hasPbr && !hasLights) {
      studio = root.add(Group(name: 'Viewer studio'))
        ..add(
          DirectionalLight(intensity: 3)
            ..rotateY(-.5)
            ..rotateX(-.5),
        )
        ..add(
          HemisphereLight(
            intensity: .7,
            groundColor: const Color3(.15, .18, .25),
          ),
        );
    }
  }

  List<String> objectNames(Object3D root) {
    final result = <String>[], pending = [root];
    while (pending.isNotEmpty) {
      final object = pending.removeLast();
      result.add(object.name ?? (object is Mesh ? 'Mesh' : 'Group'));
      pending.addAll(object.children.reversed);
    }
    return result;
  }

  void loadUri() {
    try {
      final uri = Uri.parse(address.text.trim());
      unawaited(load(Gltf.uri(uri, options: options)));
    } catch (failure) {
      setState(() {
        error = 'Enter an absolute model URI. $failure';
      });
    }
  }

  void cancel() {
    generation++;
    task?.cancel();
    task = null;
    unawaited(progress?.cancel());
    progress = null;
    setState(() {
      busy = false;
      status = 'Cancelled';
    });
  }

  void clear() {
    cancel();
    animationRegistration?.dispose();
    animationRegistration = null;
    instance?.mixer.stopAll();
    action = null;
    if (instance case final old?) controller.scene.remove(old);
    if (model case final old?) controller.assets.release(old);
    setState(() {
      model = null;
      instance = null;
      studio = null;
      names = const [];
      error = '';
      status = 'Choose a model';
    });
  }

  Future<void> changeScene(int? index) async {
    if (index == null || model == null || busy) return;
    final ticket = ++generation;
    setState(() {
      busy = true;
      error = '';
      status = 'Preparing scene';
    });
    try {
      final next = model!.instantiate(sceneIndex: index);
      final bounds = await modelBounds(next, () => stale(ticket));
      if (stale(ticket)) return;
      controller.scene.remove(instance!);
      configureAnimation(next);
      configureLighting(next);
      controller.scene.add(next);
      setState(() {
        instance = next;
        selectedScene = index;
        names = objectNames(next);
        status = '${names.length} objects';
      });
      target = bounds.center;
      radius = bounds.radius;
      resetCamera();
    } on LoadCancelled {
      // A newer load or route removal owns the UI now.
    } catch (failure) {
      if (!stale(ticket)) {
        setState(() {
          error = failure.toString();
        });
      }
    } finally {
      if (!stale(ticket)) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  void showObjects() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Objects'),
      content: SizedBox(
        width: 340,
        height: 300,
        child: names.isEmpty
            ? const ZeroState(
                title: 'No objects',
                message: 'Load a model to inspect its hierarchy.',
              )
            : ListView.builder(
                itemCount: names.length,
                itemBuilder: (context, index) =>
                    ListTile(dense: true, title: Text(names[index])),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
  @override
  void dispose() {
    generation++;
    task?.cancel();
    unawaited(progress?.cancel());
    for (final registration in gestures) {
      registration.dispose();
    }
    animationRegistration?.dispose();
    unawaited(frames?.cancel());
    controller.dispose();
    address.dispose();
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
            Row(
              children: [
                const Expanded(
                  child: Text('Model viewer', style: TextStyle(fontSize: 20)),
                ),
                if (studio != null)
                  IconButton(
                    tooltip: 'Studio light',
                    isSelected: studio!.visible,
                    onPressed: () =>
                        setState(() => studio!.visible = !studio!.visible),
                    icon: const Icon(Icons.light_mode_outlined),
                    selectedIcon: const Icon(Icons.light_mode),
                  ),
                IconButton(
                  tooltip: 'Frame model',
                  onPressed: resetCamera,
                  icon: const Icon(Icons.center_focus_strong),
                ),
                IconButton(
                  tooltip: 'Clear model',
                  onPressed: model == null ? null : clear,
                  icon: const Icon(Icons.clear),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: address,
                    onSubmitted: (_) => loadUri(),
                    decoration: const InputDecoration(
                      isDense: true,
                      labelText: 'Model URI',
                      hintText: 'https://host/model.glb',
                    ),
                  ),
                ),
                PopupMenuButton<bool>(
                  tooltip: 'Material mode',
                  icon: const Icon(Icons.tune),
                  initialValue: diagnostic,
                  onSelected: (value) => setState(() => diagnostic = value),
                  itemBuilder: (_) => [
                    CheckedPopupMenuItem(
                      value: false,
                      checked: !diagnostic,
                      child: const Text('Native PBR'),
                    ),
                    CheckedPopupMenuItem(
                      value: true,
                      checked: diagnostic,
                      child: const Text('Unlit diagnostic'),
                    ),
                  ],
                ),
                IconButton(
                  tooltip: 'Load URI',
                  onPressed: loadUri,
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
            if (diagnostic)
              const Text(
                'Diagnostic mode uses unlit base color on the next load.',
                style: TextStyle(fontSize: 12),
              ),
            Row(
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Examples',
                  icon: const Icon(Icons.view_in_ar),
                  onSelected: (file) => load(bundle(file)),
                  itemBuilder: (_) => [
                    for (final (file, label) in [
                      ('assembly.glb', 'GLB'),
                      ('assembly.gltf', 'Relative glTF'),
                      ('pbr.glb', 'PBR model'),
                      ('colors.glb', 'Colors'),
                      ('normal-map.glb', 'Normal map'),
                      ('animated.glb', 'Animation'),
                      ('deformation.glb', 'Skin + morph'),
                    ])
                      PopupMenuItem(value: file, child: Text(label)),
                  ],
                ),
                Expanded(
                  child:
                      !busy &&
                          error.isEmpty &&
                          model != null &&
                          model!.scenes.length > 1
                      ? DropdownButton<int>(
                          isExpanded: true,
                          value: selectedScene,
                          onChanged: changeScene,
                          items: [
                            for (final scene in model!.scenes)
                              DropdownMenuItem(
                                value: scene.index,
                                child: Text(
                                  scene.name ?? 'Scene ${scene.index + 1}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        )
                      : Text(
                          status,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                ),
                if (busy)
                  TextButton(onPressed: cancel, child: const Text('Cancel'))
                else if (lastRequest != null)
                  TextButton(
                    onPressed: () => load(
                      Gltf.uri(
                        lastRequest!.uri,
                        options: options,
                        version: lastRequest!.version,
                      ),
                    ),
                    child: const Text('Retry'),
                  ),
                TextButton(
                  onPressed: showObjects,
                  child: const Text('Objects'),
                ),
              ],
            ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xffffadad)),
                ),
              ),
            if (model != null && model!.issues.isNotEmpty)
              Tooltip(
                message: model!.issues.map((i) => i.message).join('\n'),
                child: Text(
                  model!.issues.first.message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xffffd18b),
                    fontSize: 12,
                  ),
                ),
              ),
            if (action != null) animationControls(),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  SceneView(controller: controller, onPointer: pointer),
                  if (instance == null && !busy && error.isEmpty)
                    ZeroState(
                      title: 'Load a 3D model',
                      message: 'Choose the bundled model or enter a glTF URI.',
                      action: FilledButton(
                        onPressed: () => load(bundle('assembly.glb')),
                        child: const Text('Load example'),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Drag to orbit · Pinch or scroll to zoom',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );
}
