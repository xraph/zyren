import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import '../presentation.dart';

/// Advanced injection for independent, controller-owned sessions and presenters.
class SceneRuntime {
  final Future<RenderBackend> Function() backendFactory;
  final PresenterFactory presenterFactory;
  const SceneRuntime({
    this.backendFactory = NativeBackend.create,
    this.presenterFactory = ImageFramePresenter.create,
  });
}
