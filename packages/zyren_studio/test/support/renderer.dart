import 'dart:async';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

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
