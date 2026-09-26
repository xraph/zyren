import 'package:gpu3d/gpu3d.dart' as core;
import 'package:gpu3d_native/gpu3d_native.dart';

/// Flutter's engine facade retains the native default renderer.
/// Dart-only applications select their renderer through gpu3d.SceneEngine.
class SceneEngine {
  final core.SceneEngine _engine;
  SceneEngine._(this._engine);

  static Future<SceneEngine> create({
    required core.Scene scene,
    required core.Camera camera,
    core.RendererFactory rendererFactory = NativeRenderer.create,
    List<core.ScenePlugin> plugins = const [],
  }) async => SceneEngine._(
    await core.SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: rendererFactory,
      plugins: plugins,
    ),
  );

  core.Scene get scene => _engine.scene;
  core.Camera get camera => _engine.camera;
  core.RendererCapabilities get capabilities => _engine.capabilities;
  List<String> get pluginIds => _engine.pluginIds;

  Future<core.RenderedFrame> render({
    required Duration elapsed,
    required int width,
    required int height,
  }) => _engine.render(elapsed: elapsed, width: width, height: height);

  Future<void> dispose() => _engine.dispose();
}
