import 'package:zyren/zyren.dart';

/// Plugin attachment provides clocks and services. It cannot submit a frame.
final class TrainingClockRenderer implements SceneRenderer {
  @override
  final capabilities = RendererCapabilities(
    name: 'training-clock',
    features: {},
    maxDimension: 1,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) => Future.error(UnsupportedError('The training clock has no renderer.'));
  @override
  Future<void> dispose() async {}
}
