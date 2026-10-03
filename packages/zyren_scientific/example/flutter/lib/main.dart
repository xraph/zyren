import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'package:zyren_scientific/agents.dart';
import 'fixtures.dart';
import 'controls.dart';

void main() => runApp(const ScientificLab());

class ScientificLab extends StatelessWidget {
  const ScientificLab({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: scientificTheme(),
    home: const ScientificWorkbench(),
  );
}

class ScientificWorkbench extends StatefulWidget {
  const ScientificWorkbench({super.key});
  @override
  State<ScientificWorkbench> createState() => ScientificWorkbenchState();
}

class ScientificWorkbenchState extends State<ScientificWorkbench> {
  late final SceneController viewport;
  late final ScientificVolumePlugin volume;
  late final OrbitControlsPlugin orbit;
  late final TemporalScalarSource temporal;
  late final AgentRegistry agents;
  ScientificFieldView? field;
  FrameStats? stats;
  final _canvasKey = GlobalKey();
  StreamSubscription<FrameStats>? subscription;
  String selected = 'Slice';
  String? error, pick;
  bool busy = true, showProbe = false;
  int? _shownRevision;
  double time = 2, threshold = 293;
  static const modes = {
    'Slice': ScientificRepresentation.slice,
    'Isosurface': ScientificRepresentation.isosurface,
    'Vectors': ScientificRepresentation.vectors,
    'Streamline': ScientificRepresentation.streamline,
    'Temporal': ScientificRepresentation.slice,
    'Volume': ScientificRepresentation.volume,
  };
  @override
  void initState() {
    super.initState();
    final scene = Scene()..background = const Color3(.008, .012, .025);
    viewport = SceneController(
      scene: scene,
      camera: PerspectiveCamera(
        position: const Vec3(2.5, 1.8, 3.5),
        target: Vec3.zero,
        near: .05,
        far: 50,
      ),
      runtime: Platform.isAndroid
          ? const SceneRuntime.nativeAndroid()
          : (Platform.isMacOS || Platform.isIOS)
          ? const SceneRuntime.nativeMetal()
          : const SceneRuntime(),
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
    );
    volume = viewport.use(ScientificVolumePlugin());
    orbit = viewport.use(OrbitControlsPlugin(keyboard: true));
    temporal = syntheticTime();
    agents = AgentRegistry(grantedScopes: {'scientific.edit'});
    subscription = viewport.frameStats.listen((s) {
      if (mounted) {
        setState(() {
          stats = s;
          if (!busy) _syncView();
        });
      }
    });
    viewport.ready
        .then((_) async {
          if (!mounted) return;
          final view = field = ScientificFieldView(
            id: 'scientific-lab',
            scene: scene,
            grid: syntheticField(),
            transfer: syntheticTransfer(),
            coordinateTolerance: 1e-5,
            scalarTolerance: 2e-5,
            vectors: syntheticVectors(),
            temporal: temporal,
            volume: volume.controller,
          );
          final provider = ScientificFieldAgentProvider(view);
          registerScientificField(agents, view);
          agents.register(
            AgentViewportProvider(
              sceneId: 'scientific-scene',
              documentId: 'synthetic-fixtures-v1',
              instanceId: 'scientific-viewport',
              scene: scene,
              camera: () => viewport.camera,
              viewport: () {
                final box =
                    _canvasKey.currentContext?.findRenderObject() as RenderBox?;
                return ViewportMetrics(
                  box?.size.width ?? 0,
                  box?.size.height ?? 0,
                  devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                );
              },
              metadata: provider.metadata,
              units: 'm',
            ),
          );
          await act(
            () => view.configure(
              expectedRevision: view.revision,
              sliceIndex: 10,
              threshold: threshold,
              seed: const Vec3(.4, 1, 1),
              vectorScale: .2,
              volumeSampleDistance: .1,
            ),
          );
        })
        .catchError((Object e) {
          if (mounted) {
            setState(() {
              error = e.toString();
              busy = false;
            });
          }
        });
  }

  Future<void> act(Future<void> Function() work) async {
    if (mounted) setState(() => busy = true);
    try {
      await work();
      viewport.invalidate();
      if (mounted) {
        setState(() {
          error = null;
          _syncView();
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          _syncView();
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> select(String label) async {
    final view = field;
    if (view == null || label == selected) return;
    await act(() async {
      await view.configure(
        expectedRevision: view.revision,
        representation: modes[label],
        time: label == 'Temporal' ? time : null,
        clearTime: label == 'Slice',
      );
      if (mounted) {
        setState(() {
          selected = label;
          pick = null;
        });
      }
    });
  }

  Future<void> seek(double value) async {
    final view = field;
    if (view == null) return;
    await act(() async {
      await view.configure(expectedRevision: view.revision, time: value);
      if (mounted) setState(() => time = value);
    });
  }

  @override
  void dispose() {
    subscription?.cancel();
    agents.dispose();
    unawaited(() async {
      await field?.dispose();
      await temporal.dispose();
      viewport.dispose();
    }());
    super.dispose();
  }

  void _syncView() {
    final view = field;
    if (view == null || view.isDisposed || _shownRevision == view.revision) {
      return;
    }
    _shownRevision = view.revision;
    final data = view.describe();
    selected =
        view.representation == ScientificRepresentation.slice &&
            view.time != null
        ? 'Temporal'
        : modes.entries.firstWhere((e) => e.value == view.representation).key;
    threshold = data['threshold'] as double;
    time = view.time?.time ?? time;
    pick = null;
  }

  Future<void> moveHistory(bool redo) async {
    final view = field;
    if (busy || view == null) return;
    await act(() async {
      if (redo) {
        await view.redo(expectedRevision: view.revision);
      } else {
        await view.undo(expectedRevision: view.revision);
      }
    });
  }

  void cameraAction(String action) {
    final controls = orbit.controls;
    if (controls == null) return;
    switch (action) {
      case 'Rotate left':
        controls.rotateLeft(.2);
      case 'Rotate right':
        controls.rotateLeft(-.2);
      case 'Rotate up':
        controls.rotateUp(.2);
      case 'Rotate down':
        controls.rotateUp(-.2);
      case 'Zoom in':
        controls.dollyIn(.8);
      case 'Zoom out':
        controls.dollyOut(.8);
      case 'Reset camera':
        controls.reset();
    }
    controls.update();
    viewport.invalidate();
  }

  Future<void> sampleSource() async {
    if (field == null || busy) return;
    setState(() => showProbe = !showProbe);
  }

  String sampleValue(List<double> position) {
    final view = field!;
    final data = view.sample(Vec3.array(position));
    final scalar = (data['value'] as double?)?.toStringAsFixed(3) ?? 'missing';
    final vector = (data['vector'] as List?)
        ?.map((v) => (v as num).toStringAsFixed(3))
        .join(', ');
    return 'Scalar $scalar ${view.grid.valueUnit.symbol}. '
        '${vector == null ? '' : 'Vector $vector ${view.vectors!.x.valueUnit.symbol}. '}'
        'Coordinates are relative to the source origin.';
  }

  @override
  Widget build(BuildContext context) {
    final view = field;
    final state = view?.isDisposed == false ? view!.describe() : null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () =>
            moveHistory(false),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): () =>
            moveHistory(false),
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): () =>
            moveHistory(true),
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          meta: true,
          shift: true,
        ): () =>
            moveHistory(true),
      },
      child: FocusTraversalGroup(
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, bounds) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: bounds.maxHeight * .55,
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          children: [
                            ScientificControls(
                              selected: selected,
                              unit: view?.activeUnit.symbol ?? 'K',
                              presentation: stats == null
                                  ? 'Preparing view'
                                  : '${stats!.presentationPath.name} · ${stats!.readbackBytes} B readback',
                              busy: busy,
                              ready: view != null,
                              canUndo: view?.canUndo ?? false,
                              canRedo: view?.canRedo ?? false,
                              undoLabel:
                                  view?.history['undoLabel'] as String? ?? '',
                              redoLabel:
                                  view?.history['redoLabel'] as String? ?? '',
                              time: time,
                              threshold: threshold,
                              onMode: select,
                              onCamera: cameraAction,
                              onUndo: () => moveHistory(false),
                              onRedo: () => moveHistory(true),
                              onSample: sampleSource,
                              onPreview: (v) => setState(() {
                                if (selected == 'Temporal') {
                                  time = v;
                                } else {
                                  threshold = v;
                                }
                              }),
                              onCommit: (v) {
                                if (selected == 'Temporal') {
                                  seek(v);
                                } else {
                                  act(
                                    () => view!.configure(
                                      expectedRevision: view.revision,
                                      threshold: v,
                                    ),
                                  );
                                }
                              },
                            ),
                            if (showProbe && view != null)
                              ScientificProbe(
                                maximum: [
                                  (view.grid.sizeX - 1) * view.grid.spacing.x,
                                  (view.grid.sizeY - 1) * view.grid.spacing.y,
                                  (view.grid.sizeZ - 1) * view.grid.spacing.z,
                                ],
                                unit: view.grid.coordinateUnit.symbol,
                                sample: sampleValue,
                                enabled: !busy,
                                onClose: () =>
                                    setState(() => showProbe = false),
                              ),
                            if (error != null)
                              Semantics(
                                liveRegion: true,
                                child: ZeroState(
                                  title: 'Scientific view failed',
                                  message: error!,
                                  actionLabel: 'Retry',
                                  onAction: busy || view == null
                                      ? null
                                      : () => act(
                                          () => view.configure(
                                            expectedRevision: view.revision,
                                          ),
                                        ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) => Listener(
                          onPointerDown: (event) {
                            if (busy || view?.mesh == null) return;
                            final hit = Raycaster()
                                .captureFromCamera(
                                  viewport.scene,
                                  viewport.camera,
                                  ViewportPoint(
                                    event.localPosition.dx,
                                    event.localPosition.dy,
                                  ),
                                  logicalWidth: constraints.maxWidth,
                                  logicalHeight: constraints.maxHeight,
                                )
                                .intersectFirst();
                            if (hit == null) return;
                            final info = view!.inspectHit(hit);
                            setState(
                              () => pick =
                                  '${info['representation']} · ${(info['value'] as double?)?.toStringAsFixed(3) ?? 'missing'} ${view.activeUnit.symbol}${info['sourceCell'] == null ? '' : ' · cell ${info['sourceCell']}'}',
                            );
                          },
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: Semantics(
                                  container: true,
                                  label: 'Scientific viewport',
                                  value:
                                      '$selected. Synthetic ${view?.activeSource.description ?? 'scientific field'}. ${state?['missingSamples'] ?? 0} missing samples.',
                                  hint:
                                      'Use Camera controls to navigate and Sample source to inspect values.',
                                  child: SceneView(
                                    key: _canvasKey,
                                    controller: viewport,
                                    loadingBuilder: (_) => const ZeroState(
                                      title: 'Preparing native view',
                                      message:
                                          'Loading the synthetic scientific fields.',
                                    ),
                                    errorBuilder: (_, issue, retry) =>
                                        ZeroState(
                                          title: 'Native view unavailable',
                                          message: issue.message,
                                          actionLabel: 'Retry',
                                          onAction: retry,
                                        ),
                                  ),
                                ),
                              ),
                              if (state?['empty'] == true &&
                                  !busy &&
                                  error == null)
                                ZeroState(
                                  title: 'No geometry at these settings',
                                  message:
                                      'Choose a slice or adjust the field controls to find valid samples.',
                                  actionLabel: 'Show slice',
                                  onAction: () => select('Slice'),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: bounds.maxHeight * .2,
                      ),
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                          child: Semantics(
                            liveRegion: true,
                            child: Wrap(
                              spacing: 16,
                              runSpacing: 4,
                              children: [
                                Text(
                                  pick ??
                                      'Gaussian temperature pulse · steady rotational vectors',
                                  key: const ValueKey('pick-status'),
                                ),
                                if (state != null)
                                  Text(
                                    selected == 'Volume'
                                        ? '${state['volumeSampleCount']} voxels · ${state['missingSamples']} missing'
                                        : '${state['cells'] ?? state['segments'] ?? 0} ${state['segments'] == null ? 'triangles/cells' : 'segments'} · ${state['missingSamples']} missing',
                                  ),
                                if (selected == 'Volume')
                                  const Text(
                                    'Opacity per 0.1 m · opaque depth clipping',
                                  ),
                                if (state?['streamlineTermination'] != null)
                                  Text(
                                    'Stop: ${state!['streamlineTermination']}',
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
