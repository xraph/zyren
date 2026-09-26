import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:gpu3d/rendering.dart';

class TestRenderer implements RenderBackend {
  final String name;
  final List<String> events;
  final Completer<void>? gate;
  int renders = 0, disposals = 0;
  final List<(int, int)> sizes = [];
  TestRenderer(this.events, {this.name = 'test', this.gate});
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: name,
    features: {RenderFeature.indexedMeshes, RenderFeature.rgbaReadback},
    limits: DeviceLimits(maxTextureDimension2D: 64, maxGeometryBytes: 1000000),
  );
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    if (disposals != 0) throw StateError('Rendering after disposal.');
    final size = submission.size;
    renders++;
    sizes.add((size.width, size.height));
    events.add('$name.render');
    await gate?.future;
    return ReadbackOutput(
      image: ImageData(
        pixels: Uint8List(size.width * size.height * 4),
        size: size,
      ),
      stats: FrameStats(
        frameId: renders,
        physicalSize: size,
        presentationPath: PresentationPath.readback,
        cpuBuildTime: Duration.zero,
        cpuSubmitTime: Duration.zero,
        drawCalls: submission.scene.drawCalls,
        triangles: submission.scene.triangles,
        readbackBytes: size.width * size.height * 4,
        uploadedBytes: 0,
      ),
    );
  }

  @override
  Future<void> close() async {
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
  final Set<String> requiredFeatures;
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
  void afterRender(PluginContext context, FrameInfo info, RenderedFrame frame) {
    events.add('$id.after');
  }

  @override
  FutureOr<void> detach(PluginContext context) {
    events.add('$id.detach');
    return onDetach?.call(context);
  }
}

class TestPresenter implements FramePresenter {
  final String label;
  final List<String> events;
  final Completer<void>? gate;
  final List<TestPresentedFrame> frames = [];
  int disposals = 0;
  TestPresenter(this.label, this.events, {this.gate});
  @override
  Future<PresentedFrame> present(RenderedFrame frame) async {
    events.add('$label.present');
    await gate?.future;
    if (disposals != 0) {
      throw StateError('Presenter disposed during conversion.');
    }
    final presented = TestPresentedFrame(label);
    frames.add(presented);
    return presented;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    events.add('$label.dispose');
  }
}

class TestPresentedFrame implements PresentedFrame {
  final String label;
  int disposals = 0;
  bool failOnDispose = false;
  TestPresentedFrame(this.label);
  @override
  Widget build(BuildContext context) => Text(label);
  @override
  void dispose() {
    disposals++;
    if (disposals > 1) throw StateError('Frame disposed twice.');
    if (failOnDispose) throw StateError('Frame cleanup failed.');
  }
}
