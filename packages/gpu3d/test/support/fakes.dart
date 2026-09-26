import 'package:gpu3d/rendering.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';

class TestRenderer implements SceneRenderer {
  final String name;
  final List<String> events;
  final Completer<void>? gate;
  int renders = 0, disposals = 0;
  final List<(int, int)> sizes = [];
  TestRenderer(this.events, {this.name = 'test', this.gate});
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: name,
    features: {RenderFeatures.indexedMeshes, RenderFeatures.rgbaReadback},
    maxDimension: 64,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async {
    if (disposals != 0) throw StateError('Rendering after disposal.');
    renders++;
    sizes.add((width, height));
    events.add('$name.render');
    await gate?.future;
    return RenderedFrame(Uint8List(width * height * 4), width, height);
  }

  @override
  Future<void> dispose() async {
    disposals++;
    events.add('$name.dispose');
  }
}

class TestPlugin extends ScenePlugin {
  @override
  final String id;
  @override
  final Set<String> dependencies;
  @override
  final Set<RenderFeature> requiredFeatures;
  final List<String> events;
  final FutureOr<void> Function(PluginContext)? onAttach, onDetach;
  final FutureOr<void> Function(PluginContext, FrameInfo)? onBefore;
  final List<FrameInfo> frames = [];
  TestPlugin(
    this.id,
    this.events, {
    this.dependencies = const {},
    this.requiredFeatures = const {},
    this.onAttach,
    this.onDetach,
    this.onBefore,
  });
  @override
  FutureOr<void> attach(PluginContext context) {
    events.add('$id.attach');
    return onAttach?.call(context);
  }

  @override
  FutureOr<void> beforeRender(PluginContext context, FrameInfo frame) {
    events.add('$id.before');
    frames.add(frame);
    return onBefore?.call(context, frame);
  }

  @override
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) {
    events.add('$id.after');
  }

  @override
  FutureOr<void> detach(PluginContext context) {
    events.add('$id.detach');
    return onDetach?.call(context);
  }
}
