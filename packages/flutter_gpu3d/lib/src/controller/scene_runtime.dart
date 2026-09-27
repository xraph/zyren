import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import '../presentation.dart';
import '../presentation/output_presenter.dart';
import '../presentation/native_texture_presenter.dart';

/// Advanced injection for independent, controller-owned sessions and presenters.
class SceneRuntime {
  final Future<RenderBackend> Function() backendFactory;
  final PresenterFactory presenterFactory;
  final SurfacePresenterFactory? surfacePresenterFactory;
  final SurfacePresenterFactory? nativeViewPresenterFactory;
  const SceneRuntime({
    this.nativeViewPresenterFactory,
    this.surfacePresenterFactory = const NativeTexturePresenterFactory(),
    this.backendFactory = NativeBackend.create,
    this.presenterFactory = ImageFramePresenter.create,
  });
}
