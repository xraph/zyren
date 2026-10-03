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
    hdrImageDecoder: NativeHdrImageDecoder(),
    tangentGenerator: NativeTangentGenerator(),
  );
  final AssetServices assetServices;
  final Future<RenderBackend> Function() backendFactory;
  final PresenterFactory presenterFactory;
  final SurfacePresenterFactory? surfacePresenterFactory;
  final SurfacePresenterFactory? nativeViewPresenterFactory;
  final int? resourceBudgetBytes;

  /// Scene upload target per frame. An indivisible asset may exceed it alone.
  final int? sceneUploadBudgetBytes;

  /// Opt-in Vulkan SurfaceProducer runtime for Android API 29 or newer.
  const SceneRuntime.nativeAndroid({
    this.assetServices = defaultAssetServices,
    this.resourceBudgetBytes,
    this.sceneUploadBudgetBytes,
  }) : backendFactory = NativeAndroidBackend.create,
       presenterFactory = ImageFramePresenter.create,
       surfacePresenterFactory = const NativeAndroidPresenterFactory(),
       nativeViewPresenterFactory = null;

  /// Opt-in Metal platform view runtime for macOS and iOS.
  const SceneRuntime.nativeMetal({
    this.assetServices = defaultAssetServices,
    this.resourceBudgetBytes,
    this.sceneUploadBudgetBytes,
  }) : backendFactory = NativeMetalBackend.create,
       presenterFactory = ImageFramePresenter.create,
       surfacePresenterFactory = null,
       nativeViewPresenterFactory = const NativeMetalPresenterFactory();

  const SceneRuntime({
    this.assetServices = defaultAssetServices,
    this.resourceBudgetBytes,
    this.sceneUploadBudgetBytes,
    this.nativeViewPresenterFactory,
    this.surfacePresenterFactory = const NativeTexturePresenterFactory(),
    this.backendFactory = NativeBackend.create,
    this.presenterFactory = ImageFramePresenter.create,
  });

  Future<RenderBackend> createBackend() async {
    final backend = await backendFactory();
    try {
      if (sceneUploadBudgetBytes case final bytes?) {
        if (backend is! SceneUploadBudgetBackend) {
          throw UnsupportedError(
            'Scene upload pacing requires backend support.',
          );
        }
        backend.configureSceneUploadBudget(bytes);
      }
      if (resourceBudgetBytes case final bytes?) {
        if (backend is! NativeGpuBackend) {
          throw UnsupportedError(
            'Resource budgets require a native GPU backend.',
          );
        }
        await backend.configureResourceBudget(bytes);
      }
      return backend;
    } catch (_) {
      await backend.close();
      rethrow;
    }
  }
}
