import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_pipeline/studio.dart';
import 'package:zyren_studio/streaming.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_tools/zyren_tools.dart';

/// A Flutter consumer of exported scenes, using the same native scene graph.
/// Supply a file, Flutter asset or bounded HTTP reader through [read].
class ZyrenRuntimeScene extends StatefulWidget {
  final Uri uri;
  final ZyrenRead read;
  final SceneRuntime runtime;
  final ValueChanged<Object3D?>? onSelection;
  final StudioExtensionRegistry? extensions;
  final void Function(SceneController, ZyrenSceneStream)? onReady;
  final void Function(SceneController, StudioScene)? onChunkLoaded;
  const ZyrenRuntimeScene({
    super.key,
    required this.uri,
    required this.read,
    this.runtime = const SceneRuntime.nativeMetal(),
    this.onSelection,
    this.extensions,
    this.onReady,
    this.onChunkLoaded,
  });
  @override
  State<ZyrenRuntimeScene> createState() => _ZyrenRuntimeSceneState();
}

class _ZyrenRuntimeSceneState extends State<ZyrenRuntimeScene> {
  final cancel = StudioCancellation();
  ZyrenSceneStream? stream;
  SceneController? controller;
  StreamSubscription<void>? selection;
  String? error;
  int count = 0, total = 0;
  @override
  void initState() {
    super.initState();
    unawaited(open());
  }

  Future<void> open() async {
    try {
      late ZyrenSceneStream opened;
      final resolver = PipelineStudioAssetResolver(
        PipelineAssetLibrary(
          services: SceneRuntime.defaultAssetServices,
          readBundle: (version, cancellation) async {
            cancellation.throwIfCancelled();
            final bytes = await opened.readResource(version);
            cancellation.throwIfCancelled();
            return PipelineBundle.decode(bytes);
          },
        ),
      );
      opened = await ZyrenSceneStream.open(
        widget.uri,
        read: widget.read,
        assets: resolver,
        extensions: widget.extensions,
        cancellation: cancel,
      );
      if (!mounted) {
        await opened.close();
        return;
      }
      stream = opened;
      final tools = SceneToolsPlugin(highlightSelection: false);
      final view = SceneController(
        scene: opened.scene,
        camera: opened.camera,
        runtime: widget.runtime,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
      );
      view.use(tools);
      view.use(OrbitControlsPlugin());
      selection = tools.changes.listen(
        (_) => widget.onSelection?.call(tools.selected),
      );
      setState(() {
        controller = view;
        total = opened.chunkIds.length;
      });
      widget.onReady?.call(view, opened);
      for (final id in opened.chunkIds) {
        cancel.throwIfCancelled();
        final chunk = await opened.loadChunk(id);
        widget.onChunkLoaded?.call(view, chunk);
        if (!mounted) return;
        setState(() => count++);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    cancel.cancel();
    unawaited(selection?.cancel());
    final view = controller;
    view?.dispose();
    unawaited(
      (view?.whenDisposed ?? Future.value()).then((_) => stream?.close()),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => error != null
      ? ZeroState(title: 'Scene unavailable', message: error!)
      : controller == null
      ? const Center(child: CircularProgressIndicator())
      : Stack(
          children: [
            Positioned.fill(child: SceneView(controller: controller!)),
            if (count < total)
              Positioned(
                left: 12,
                bottom: 12,
                child: Text('Loading $count / $total'),
              ),
          ],
        );
}
