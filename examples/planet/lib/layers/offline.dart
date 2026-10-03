import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import '../zero_state.dart';
import 'offline_fixture.dart';

class OfflineLab extends StatefulWidget {
  final Directory? directory;
  const OfflineLab({super.key, this.directory});
  @override
  State<OfflineLab> createState() => OfflineLabState();
}

class OfflineLabState extends State<OfflineLab> {
  OfflineRepository? repository;
  OfflineView? view;
  SceneController? controller;
  GeoDataDiagnosticsSnapshot? diagnostics;
  GeoSample<double>? depth;
  bool _disposing = false;
  bool offline = false, _busy = true, _downloading = false;
  String _message = 'Opening saved region';
  Object? _error;
  Directory? _directory;
  StreamSubscription<GeoRegionProgress>? _progress;
  StreamSubscription<GeoLayerChange>? _layers;
  Future<void>? _shutdownFuture;
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    try {
      _directory ??=
          widget.directory ??
          Directory(
            '${(await getApplicationSupportDirectory()).path}/zyren/offline-coast',
          );
      final opened = await OfflineRepository.open(_directory!);
      if (!mounted || _disposing) {
        await opened.close();
        return;
      }
      repository = opened;
      _progress = opened.job.changes.listen((_) {
        if (mounted && !_disposing) setState(() {});
      });
      _message = opened.job.plan == null
          ? 'No saved region'
          : 'Saved bytes verified';
      await _refreshView();
      await _inspect();
    } catch (error) {
      _error = error;
    } finally {
      if (mounted && !_disposing) setState(() => _busy = false);
    }
  }

  Future<void> _disposeScene() async {
    final session = controller;
    controller = null;
    if (mounted && !_disposing) setState(() {});
    await _layers?.cancel();
    _layers = null;
    session?.dispose();
    await session?.whenDisposed;
    view?.dispose();
    view = null;
    depth = null;
  }

  Future<void> _refreshView() async {
    await _disposeScene();
    if (!mounted ||
        _disposing ||
        !(await repository!.hasCoverage) ||
        !mounted ||
        _disposing) {
      return;
    }
    final next = repository!.createView(offline: offline);
    final session = SceneController(
      scene: next.scene,
      camera: next.camera,
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
      runtime: defaultTargetPlatform == TargetPlatform.android
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
    );
    for (final plugin in next.geo.scenePlugins) {
      session.use(plugin);
    }
    view = next;
    controller = session;
    _layers = next.geo.layers.changes.listen((_) {
      if (mounted && !_disposing) setState(() {});
    });
    depth = await next.bathymetry.sample(
      Geodetic(-.0002, 0),
      GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026)),
    );
    if (mounted && !_disposing) setState(() {});
  }

  Future<void> _inspect() async {
    diagnostics = await repository?.diagnostics.snapshot();
    if (mounted && !_disposing) setState(() {});
  }

  Future<void> _download() async {
    if (_busy || offline) return;
    setState(() {
      _busy = true;
      _downloading = true;
      _error = null;
    });
    try {
      final result = await repository!.download();
      _message = result.complete
          ? 'Region verified and pinned'
          : repository!.job.progress.state == GeoRegionJobState.paused
          ? 'Download paused; verified bytes retained'
          : 'Download failed: ${result.failures.values.firstOrNull?.name ?? 'incomplete'}';
      if (mounted && !_disposing) await _refreshView();
    } catch (error) {
      _error = error;
      _message = 'Download failed';
    } finally {
      if (mounted && !_disposing) {
        await _inspect();
        setState(() {
          _busy = false;
          _downloading = false;
        });
      }
    }
  }

  Future<void> _cancel() async {
    try {
      await repository!.job.cancel();
    } catch (error) {
      if (mounted && !_disposing) setState(() => _error = error);
    }
  }

  Future<void> _setOffline(bool value) async {
    if (_busy) return;
    setState(() {
      offline = value;
      _busy = true;
      _error = null;
    });
    try {
      await _refreshView();
      await _inspect();
      _message = value
          ? 'Offline view rebuilt from saved bytes'
          : 'Cache-first view';
    } catch (error) {
      _error = error;
    } finally {
      if (mounted && !_disposing) setState(() => _busy = false);
    }
  }

  Future<void> _reopen() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _disposeScene();
      await _progress?.cancel();
      await repository?.close();
      repository = null;
      await _open();
    } catch (error) {
      if (mounted && !_disposing) {
        setState(() {
          _error = error;
          _busy = false;
        });
      }
    }
  }

  Future<void> shutdown() => _shutdownFuture ??= _shutdown();
  Future<void> _shutdown() async {
    await _disposeScene();
    await _progress?.cancel();
    await repository?.close();
  }

  @override
  void dispose() {
    _disposing = true;
    unawaited(shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = repository, session = controller;
    final progress = repo?.job.progress;
    final state = progress?.state.name ?? 'opening';
    final failed = progress?.state == GeoRegionJobState.failed;
    final paused = progress?.state == GeoRegionJobState.paused;
    final ready =
        view != null &&
        view!.geo.layers.snapshot.isNotEmpty &&
        view!.geo.layers.layer('terrain').status.data ==
            GeoLayerDataState.ready;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.offline_pin_outlined, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Offline coast lab',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (Navigator.of(context).canPop())
                    IconButton(
                      tooltip: 'Back',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      key: const Key('download'),
                      onPressed: _busy || offline || repo == null
                          ? null
                          : _download,
                      icon: const Icon(Icons.download, size: 17),
                      label: Text(
                        failed
                            ? 'Retry'
                            : paused
                            ? 'Resume'
                            : 'Download',
                      ),
                    ),
                    TextButton(
                      key: const Key('cancel'),
                      onPressed: _downloading ? _cancel : null,
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      key: const Key('reopen'),
                      onPressed: _busy || repo == null ? null : _reopen,
                      child: const Text('Reopen'),
                    ),
                    FilterChip(
                      label: const Text('Offline only'),
                      selected: offline,
                      onSelected: _busy || repo == null ? null : _setOffline,
                    ),
                    FilterChip(
                      label: const Text('Deny source'),
                      selected: repo?.denySource ?? false,
                      onSelected: _busy || repo == null
                          ? null
                          : (v) => setState(() => repo.denySource = v),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$state · ${progress?.verifiedResources ?? 0}/${progress?.requiredResources ?? 3} verified · '
                  '${diagnostics?.tiers?.diskPayloadBytes ?? 'unknown'} B saved\n${_error ?? _message}',
                  key: const Key('offline-status'),
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ),
            Expanded(
              child: session == null
                  ? _busy
                        ? const Center(child: CircularProgressIndicator())
                        : ZeroState(
                            title: _error != null
                                ? 'Saved region could not open'
                                : 'Save a region to explore offline',
                            message: _error != null
                                ? '$_error'
                                : 'Download the finite synthetic coast, elevation and depth fields. Each saved resource is verified before use.',
                            actionLabel: _error != null
                                ? 'Retry storage'
                                : offline
                                ? 'Go online'
                                : paused
                                ? 'Resume download'
                                : 'Download region',
                            onAction: _error != null
                                ? _reopen
                                : offline
                                ? () => _setOffline(false)
                                : _download,
                          )
                  : Stack(
                      children: [
                        Positioned.fill(
                          child: SceneView(
                            controller: session,
                            errorBuilder: (context, issue, retry) =>
                                RendererZeroState(error: issue, onRetry: retry),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          top: 10,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: const Color(0xdd080e19),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                                child: Text(
                                  '${ready ? 'Terrain ready' : 'Loading saved terrain'}\nDepth probe: ${depth?.value?.toStringAsFixed(1) ?? 'unavailable'} m',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Synthetic field colours · finite coverage · native GPU\nBlue: depth · green: elevation · lines: 25 m contours',
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
