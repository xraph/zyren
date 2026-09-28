import 'package:zyren/rendering.dart';
import 'package:zyren/zyren.dart' show AssetServices;
import 'package:zyren_native/zyren_native.dart';
import '../presentation.dart';
import '../presentation/output_presenter.dart';
import '../presentation/native_texture_presenter.dart';
import '../presentation/native_metal_presenter.dart';
import '../presentation/native_android_presenter.dart';
import '../assets/flutter_source_resolver.dart';

/// Advanced injection for independent, controller-owned sessions and presenters.
class SceneRuntime {
  static const defaultAssetServices = AssetServices(
    resolver: FlutterSourceResolver(),
    imageDecoder: NativeImageDecoder(),
    textureDecoder: NativeTextureDecoder(),
    bufferDecoder: NativeBufferDecoder(),
    meshDecoder: NativeMeshDecoder(),
  );
  final AssetServices assetServices;
  final Future<RenderBackend> Function() backendFactory;
  final PresenterFactory presenterFactory;
  final SurfacePresenterFactory? surfacePresenterFactory;
  final SurfacePresenterFactory? nativeViewPresenterFactory;

  /// Opt-in Vulkan SurfaceProducer runtime for Android API 29 or newer.
  const SceneRuntime.nativeAndroid({this.assetServices = defaultAssetServices})
    : backendFactory = NativeAndroidBackend.create,
      presenterFactory = ImageFramePresenter.create,
      surfacePresenterFactory = const NativeAndroidPresenterFactory(),
      nativeViewPresenterFactory = null;

  /// Opt-in Metal platform view runtime for macOS and iOS.
  const SceneRuntime.nativeMetal({this.assetServices = defaultAssetServices})
    : backendFactory = NativeMetalBackend.create,
      presenterFactory = ImageFramePresenter.create,
      surfacePresenterFactory = null,
      nativeViewPresenterFactory = const NativeMetalPresenterFactory();

  const SceneRuntime({
    this.assetServices = defaultAssetServices,
    this.nativeViewPresenterFactory,
    this.surfacePresenterFactory = const NativeTexturePresenterFactory(),
    this.backendFactory = NativeBackend.create,
    this.presenterFactory = ImageFramePresenter.create,
  });
}
