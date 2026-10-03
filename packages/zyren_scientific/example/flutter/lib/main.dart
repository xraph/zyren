import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'package:zyren_scientific/agents.dart';
import 'fixtures.dart';

void main() => runApp(const ScientificLab());

class ScientificLab extends StatelessWidget {
  const ScientificLab({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(
      useMaterial3: true,
    ).copyWith(visualDensity: VisualDensity.compact),
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
  late final TemporalScalarSource temporal;
  late final AgentRegistry agents;
  ScientificFieldView? field;
  FrameStats? stats;
  final _canvasKey = GlobalKey();
  StreamSubscription<FrameStats>? subscription;
  String selected = 'Slice';
  String? error, pick;
  bool busy = true;
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
    viewport.use(OrbitControlsPlugin());
    temporal = syntheticTime();
    agents = AgentRegistry(grantedScopes: {'scientific.edit'});
    subscription = viewport.frameStats.listen((s) {
      if (mounted) setState(() => stats = s);
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
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> select(String label) async {
    final view = field;
    if (view == null) return;
    await act(() async {
      await view.configure(
        expectedRevision: view.revision,
        representation: modes[label],
        time: label == 'Temporal' ? time : null,
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

  @override
  Widget build(BuildContext context) {
    final view = field;
    final state = view?.isDisposed == false ? view!.describe() : null;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Scientific lab',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text('SYNTHETIC · ${view?.activeUnit.symbol ?? 'K'} · m'),
                  if (stats != null)
                    Text(
                      '${stats!.presentationPath.name} · ${stats!.readbackBytes} B readback',
                      key: const ValueKey('presentation-status'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 4,
                runSpacing: 2,
                children: [
                  for (final label in modes.keys)
                    ChoiceChip(
                      key: ValueKey('mode-$label'),
                      label: Text(label),
                      selected: label == selected,
                      onSelected: busy || view == null
                          ? null
                          : (_) => select(label),
                    ),
                ],
              ),
            ),
            if (selected == 'Isosurface' || selected == 'Temporal')
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Text(
                      selected == 'Temporal'
                          ? 'Time ${time.toStringAsFixed(2)} s'
                          : '${threshold.toStringAsFixed(1)} K',
                    ),
                    Expanded(
                      child: Slider(
                        key: const ValueKey('field-slider'),
                        value: selected == 'Temporal' ? time : threshold,
                        min: selected == 'Temporal' ? 0 : 274,
                        max: selected == 'Temporal' ? 2 : 312,
                        divisions: selected == 'Temporal' ? 20 : 76,
                        onChanged: busy
                            ? null
                            : (v) {
                                if (selected == 'Temporal') {
                                  seek(v);
                                } else {
                                  act(() async {
                                    await view!.configure(
                                      expectedRevision: view.revision,
                                      threshold: v,
                                    );
                                    if (mounted) setState(() => threshold = v);
                                  });
                                }
                              },
                      ),
                    ),
                  ],
                ),
              ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            if (error != null)
              ZeroState(
                title: 'Scientific view failed',
                message: error!,
                actionLabel: 'Retry',
                onAction: busy ? null : () => select(selected),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Listener(
                  onPointerDown: (event) {
                    if (view?.mesh == null) return;
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
                    if (hit != null) {
                      final info = view!.inspectHit(hit);
                      setState(
                        () => pick =
                            '${info['representation']} · ${(info['value'] as double?)?.toStringAsFixed(3) ?? 'missing'} ${view.activeUnit.symbol}${info['sourceCell'] == null ? '' : ' · cell ${info['sourceCell']}'}',
                      );
                    }
                  },
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: SceneView(
                          key: _canvasKey,
                          controller: viewport,
                          loadingBuilder: (_) => const ZeroState(
                            title: 'Preparing native view',
                            message: 'Loading the synthetic scientific fields.',
                          ),
                          errorBuilder: (_, issue, retry) => ZeroState(
                            title: 'Native view unavailable',
                            message: issue.message,
                            actionLabel: 'Retry',
                            onAction: retry,
                          ),
                        ),
                      ),
                      if (state?['empty'] == true && !busy && error == null)
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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
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
                    const Text('Opacity per 0.1 m · opaque depth clipping'),
                  if (state?['streamlineTermination'] != null)
                    Text('Stop: ${state!['streamlineTermination']}'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
