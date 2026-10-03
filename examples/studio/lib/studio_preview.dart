import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_studio/animation.dart';
import 'package:zyren_timeline/zyren_timeline.dart';

/// A preview has no save route and owns its scene, template scope and renderer.
class StudioPreview extends StatefulWidget {
  final StudioDocument document;
  final StudioAssetResolver? resolver;
  final SceneRuntime runtime;
  final String clipId;
  const StudioPreview({
    super.key,
    required this.document,
    required this.runtime,
    required this.clipId,
    this.resolver,
  });
  @override
  State<StudioPreview> createState() => _StudioPreviewState();
}

class _StudioPreviewState extends State<StudioPreview> {
  final _cancel = StudioCancellation();
  StudioAssetScope? _scope;
  SceneController? _controller;
  SceneTimelinePlugin? _timeline;
  StreamSubscription<void>? _changes;
  String? _error;
  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  Future<void> _open() async {
    StudioAssetScope? scope;
    try {
      if (widget.resolver != null) {
        scope = await StudioAssetScope.load(
          widget.document,
          widget.resolver!,
          cancellation: _cancel,
        );
      }
      _cancel.throwIfCancelled();
      final scene = StudioScene(widget.document, assets: scope);
      final timeline = studioTimeline(scene, widget.clipId);
      final controller = SceneController(
        scene: scene.scene,
        camera: scene.camera,
        runtime: widget.runtime,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
      );
      controller.use(timeline);
      if (!mounted) {
        controller.dispose();
        await scope?.close();
        return;
      }
      _scope = scope;
      _controller = controller;
      _timeline = timeline;
      controller.status.addListener(_refresh);
      _changes = timeline.changes.listen((_) => _refresh());
      setState(() {});
    } catch (error) {
      await scope?.close();
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _cancel.cancel();
    unawaited(_changes?.cancel());
    _controller?.status.removeListener(_refresh);
    final controller = _controller;
    controller?.dispose();
    if (controller == null) {
      unawaited(_scope?.close());
    } else {
      unawaited(controller.whenDisposed.then((_) => _scope?.close()));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final timeline = _timeline;
    final ready = controller?.status.value is SceneReady;
    return Dialog.fullscreen(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('Preview: ${widget.clipId}'),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    label: const Text('Close preview'),
                  ),
                  if (timeline != null)
                    TextButton.icon(
                      onPressed: ready
                          ? () {
                              timeline.isPlaying
                                  ? timeline.pause()
                                  : timeline.play();
                            }
                          : null,
                      icon: Icon(
                        timeline.isPlaying ? Icons.pause : Icons.play_arrow,
                      ),
                      label: Text(timeline.isPlaying ? 'Pause' : 'Play'),
                    ),
                  if (timeline != null)
                    Text(
                      '${(timeline.position.inMicroseconds / 1000000).toStringAsFixed(2)} s',
                    ),
                ],
              ),
            ),
            if (timeline != null)
              Slider(
                value: timeline.position.inMicroseconds.toDouble().clamp(
                  0,
                  timeline.duration.inMicroseconds.toDouble(),
                ),
                max: timeline.duration.inMicroseconds.toDouble(),
                onChanged: ready
                    ? (value) {
                        timeline.pause();
                        timeline.seek(Duration(microseconds: value.round()));
                      }
                    : null,
              ),
            Expanded(
              child: _error != null
                  ? ZeroState(
                      title: 'Preview unavailable',
                      message: _error!,
                      actionLabel: 'Close preview',
                      onAction: () => Navigator.pop(context),
                    )
                  : controller == null
                  ? const Center(child: CircularProgressIndicator())
                  : SceneView(controller: controller),
            ),
          ],
        ),
      ),
    );
  }
}
