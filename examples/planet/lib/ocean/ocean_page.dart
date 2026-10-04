import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'scenes/coast_store.dart';
import 'scenes/definition.dart';
import 'scenes/world.dart';
import 'widgets/lab_shell.dart';

class OceanLabPage extends StatefulWidget {
  final Directory? storageDirectory;
  final String initialScene;
  const OceanLabPage({
    super.key,
    this.storageDirectory,
    this.initialScene = 'calm',
  });
  @override
  State<OceanLabPage> createState() => OceanLabPageState();
}

class OceanLabPageState extends State<OceanLabPage> {
  List<OceanLabSceneDefinition> _scenes = [];
  OceanLabCoast? _coast;
  OceanLabWorld? world;
  SceneController? controller;
  OceanLabDetail _detail = OceanLabDetail.balanced;
  OceanWaterDebug _debug = OceanWaterDebug.color;
  late String _sceneId;
  Object? _failure;
  FrameStats? _stats;
  bool _busy = true;
  StreamSubscription<FrameStats>? _frames;
  StreamSubscription<Object?>? _layers;
  Future<void> _operation = Future.value();
  final _closed = Completer<void>();
  Future<void> get whenClosed => _closed.future;

  @override
  void initState() {
    super.initState();
    _closed.future.ignore();
    _sceneId = widget.initialScene;
    _operation = _open();
  }

  Future<void> _open() async {
    try {
      _scenes = OceanLabSceneDefinition.decode(
        await rootBundle.loadString('assets/ocean/scenes.json'),
      );
      final directory =
          widget.storageDirectory ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}/zyren/ocean-lab/coast',
          );
      _coast = await OceanLabCoast.open(
        directory,
        allowFixtureGeneration: true,
      );
      if (!mounted) return;
      await _replace();
    } catch (error) {
      if (mounted) {
        setState(() {
          _failure = error;
          _busy = false;
        });
      }
    }
  }

  SceneRuntime get _runtime => Platform.isAndroid
      ? const SceneRuntime.nativeAndroid(resourceBudgetBytes: 768 * 1024 * 1024)
      : Platform.isMacOS || Platform.isIOS
      ? const SceneRuntime.nativeMetal(resourceBudgetBytes: 768 * 1024 * 1024)
      : const SceneRuntime(resourceBudgetBytes: 768 * 1024 * 1024);

  Future<void> _replace() async {
    final previous = controller;
    setState(() {
      _busy = true;
      controller = null;
      world = null;
      _failure = null;
      _stats = null;
    });
    await _frames?.cancel();
    await _layers?.cancel();
    previous?.dispose();
    try {
      await previous?.whenDisposed;
      if (!mounted) return;
      final next = OceanLabWorld(
        _scenes.singleWhere((s) => s.id == _sceneId),
        _coast!,
        detail: _detail,
        debug: _debug,
      );
      final session = SceneController(
        scene: next.scene,
        camera: next.camera,
        options: EngineOptions(
          presentation: Platform.isMacOS || Platform.isIOS || Platform.isAndroid
              ? PresentationPolicy.requireNative
              : PresentationPolicy.allowReadback,
        ),
        runtime: _runtime,
      );
      for (final plugin in next.plugins) {
        session.use(plugin);
      }
      _frames = session.frameStats.listen((frame) {
        if (mounted && identical(controller, session)) {
          setState(() => _stats = frame);
        }
      });
      _layers = next.host.layers.changes.listen((_) {
        if (mounted && identical(controller, session)) setState(() {});
      });
      setState(() {
        world = next;
        controller = session;
        _busy = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _failure = error;
          _busy = false;
        });
      }
    }
  }

  void _restart({String? scene, OceanWaterDebug? debug}) {
    if (_busy) return;
    _sceneId = scene ?? _sceneId;
    _debug = debug ?? _debug;
    _operation = _replace();
  }

  void _change(VoidCallback action) {
    try {
      action();
      controller?.invalidate();
      setState(() => _failure = null);
    } catch (error) {
      setState(() => _failure = error);
    }
  }

  @override
  void dispose() {
    unawaited(_frames?.cancel());
    unawaited(_layers?.cancel());
    controller?.dispose();
    final closing = controller;
    final closingTask = () async {
      await _operation;
      await closing?.whenDisposed;
      await _coast?.close();
    }();
    unawaited(
      closingTask.then(_closed.complete, onError: _closed.completeError),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = controller, lab = world;
    final error =
        _failure ?? lab?.simulationFailure ?? lab?.presentation?.lastFailure;
    final effective = lab?.presentation?.effectiveQuality;
    final stats = _stats;
    final view = lab?.presentation?.view;
    final status = error != null
        ? 'Action failed: $error'
        : effective == null || view == null
        ? 'Preparing native water'
        : 'Tick ${lab!.host.clock.tick} · FFT ${effective.fftResolution} · '
              '${view.patchCount} patches · '
              '${((lab.presentation!.controller!.estimatedBytes) / 1048576).toStringAsFixed(1)} MiB planned'
              '${stats == null ? '' : ' · ${stats.physicalSize.width}×${stats.physicalSize.height}'}';
    return OceanLabShell(
      scenes: _scenes,
      sceneId: _sceneId,
      detail: _detail,
      debug: _debug,
      paused: lab?.paused ?? false,
      route: lab?.route ?? false,
      busy: _busy || session == null,
      layers: {
        for (final layer in lab?.host.layers.snapshot ?? [])
          if (layer.owner == lab!.ocean.id && !layer.isGroup)
            layer.id: layer.visible,
      },
      status: status,
      hasFailure: error != null,
      evidence: lab?.definition.hasCoast == true
          ? OceanLabCoast.credit
          : 'Procedural all-water world · Custom detail profiles · Visual review pending',
      onScene: (id) => _restart(scene: id),
      onDetail: (value) => _change(() {
        _detail = value;
        lab!.selectDetail(value);
      }),
      onDebug: (value) => _restart(debug: value),
      onLayer: (id, visible) => _change(() => lab!.setLayer(id, visible)),
      onPause: () => _change(() => lab!.paused = !lab.paused),
      onReset: () => _change(lab!.resetCamera),
      onRoute: () => _change(() => lab!.setRoute(!lab.route)),
      canvas: session != null
          ? SceneView(
              key: ObjectKey(session),
              controller: session,
              errorBuilder: (context, issue, retry) => ZeroState(
                title: 'Scene could not render',
                message: issue.toString(),
                actionLabel: 'Reload scene',
                onAction: () => _restart(),
              ),
              loadingBuilder: (_) =>
                  const Center(child: CircularProgressIndicator()),
            )
          : _failure != null
          ? ZeroState(
              title: 'Ocean lab could not open',
              message: '$_failure',
              actionLabel: 'Retry',
              onAction: () {
                if (_coast == null) {
                  setState(() => _busy = true);
                  _operation = _open();
                } else {
                  _restart();
                }
              },
            )
          : const Center(child: CircularProgressIndicator()),
    );
  }
}
