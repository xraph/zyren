import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../zero_state.dart';
import 'fixture.dart';

class LayersLab extends StatefulWidget {
  final LayersFixture? fixture;
  final File? layoutFile;
  const LayersLab({super.key, this.fixture, this.layoutFile});
  @override
  State<LayersLab> createState() => LayersLabState();
}

class LayersLabState extends State<LayersLab> {
  late final fixture = widget.fixture ?? LayersFixture();
  SceneController? controller;
  File? _file;
  Object? _error;
  String _storage = 'Opening saved layout';
  bool _saving = false;
  StreamSubscription<GeoLayerChange>? _layers;
  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start({bool restore = true}) async {
    try {
      _file ??=
          widget.layoutFile ??
          File(
            '${(await getApplicationSupportDirectory()).path}/zyren/layers.json',
          );
      final loaded = restore && await fixture.restore(_file!);
      if (!mounted) return;
      final session = SceneController(
        scene: fixture.scene,
        camera: fixture.camera,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
        runtime: defaultTargetPlatform == TargetPlatform.android
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      );
      for (final plugin in fixture.geo.scenePlugins) {
        session.use(plugin);
      }
      _layers = fixture.geo.layers.changes.listen((_) {
        if (mounted) setState(() {});
      });
      setState(() {
        controller = session;
        _error = null;
        _storage = loaded ? 'Saved layout restored' : 'Default layout';
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _storage = 'Saving layout';
    });
    try {
      await fixture.save(_file!);
      if (mounted) setState(() => _storage = 'Layout saved');
    } catch (error) {
      if (mounted) setState(() => _storage = 'Save failed: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _change(VoidCallback action) {
    action();
    controller!.invalidate();
    setState(() {});
  }

  @override
  void dispose() {
    unawaited(_layers?.cancel());
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = controller;
    return Scaffold(
      body: SafeArea(
        child: session == null
            ? (_error != null
                  ? ZeroState(
                      title: 'Saved layout could not open',
                      message: '$_error',
                      actionLabel: 'Use default layout',
                      onAction: () => _start(restore: false),
                    )
                  : const Center(child: CircularProgressIndicator()))
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: ValueListenableBuilder<SceneStatus>(
                      valueListenable: session.status,
                      builder: (context, status, _) {
                        final ready = status is SceneReady;
                        return Wrap(
                          spacing: 8,
                          runSpacing: 0,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (Navigator.canPop(context))
                              IconButton(
                                tooltip: 'Back',
                                onPressed: () => Navigator.pop(context),
                                icon: const Icon(Icons.arrow_back),
                              ),
                            const Text(
                              'Layers',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            for (final rig in ['overview', 'detail'])
                              ChoiceChip(
                                label: Text(
                                  rig == 'overview' ? 'Overview' : 'Detail',
                                ),
                                visualDensity: VisualDensity.compact,
                                selected:
                                    fixture.geo.cameras.activeRigId == rig,
                                onSelected: ready
                                    ? (_) => _change(
                                        () => fixture.geo.cameras.activate(rig),
                                      )
                                    : null,
                              ),
                            TextButton.icon(
                              onPressed: ready && !_saving ? _save : null,
                              icon: const Icon(Icons.save_outlined, size: 18),
                              label: const Text('Save layout'),
                            ),
                            Text(
                              _storage,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final layer in fixture.geo.layers.snapshot)
                          FilterChip(
                            label: Text(
                              '${layer.id == 'sky'
                                  ? 'Sky'
                                  : layer.id == 'west'
                                  ? 'West'
                                  : 'East'} · ${layer.status.data.name}',
                            ),
                            visualDensity: VisualDensity.compact,
                            selected: layer.visible,
                            onSelected: (value) => _change(
                              () => fixture.geo.layers.setVisible(
                                layer.id,
                                value,
                              ),
                            ),
                          ),
                        TextButton(
                          onPressed: () => _change(
                            fixture.eastSource.fail
                                ? fixture.retryEast
                                : fixture.failEast,
                          ),
                          child: Text(
                            fixture.eastSource.fail
                                ? 'Retry east source'
                                : 'Fail east source',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: SceneView(
                      controller: session,
                      errorBuilder: (context, issue, retry) =>
                          RendererZeroState(error: issue, onRetry: retry),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Procedural terrain · Native GPU · Saved layer layout',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
