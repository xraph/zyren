import 'dart:typed_data';
import 'capabilities.dart';
import 'frame_output.dart';
import '../scene/scene.dart';

/// Tightly packed, top-down RGBA8 pixels. The consumer owns this buffer.
class RenderedFrame {
  final Uint8List pixels;
  final int width, height;
  final int uploadedBytes, residentBytes;
  const RenderedFrame(
    this.pixels,
    this.width,
    this.height, {
    this.uploadedBytes = 0,
    this.residentBytes = 0,
  });
  factory RenderedFrame.fromImage(ImageData image) {
    if (image.format != PixelFormat.rgba8 ||
        image.colorSpace != ColorSpace.srgb) {
      throw ArgumentError('RGBA8 sRGB image required.');
    }
    if (image.rowStride == image.size.width * 4) {
      return RenderedFrame(image.pixels, image.size.width, image.size.height);
    }
    final packed = Uint8List(image.size.width * image.size.height * 4);
    for (var y = 0; y < image.size.height; y++) {
      packed.setRange(
        y * image.size.width * 4,
        (y + 1) * image.size.width * 4,
        image.pixels,
        y * image.rowStride,
      );
    }
    return RenderedFrame(packed, image.size.width, image.size.height);
  }
}

/// Stable feature identifiers that plugins can require before allocating work.
abstract final class RenderFeatures {
  static const indexedMeshes = RenderFeature.indexedMeshes;
  static const diffuseLighting = RenderFeature.diffuseLighting;
  static const unlitMaterials = RenderFeature.unlitMaterials;
  static const rgbaReadback = RenderFeature.rgbaReadback;
}

/// Compatibility capabilities for the explicit RGBA renderer interface.
class RendererCapabilities extends DeviceCapabilities {
  int get maxDimension => limits.maxTextureDimension2D;
  RendererCapabilities({
    required super.name,
    required super.features,
    required int maxDimension,
    int maxGeometryBytes = 64 * 1024 * 1024,
  }) : super(
         limits: DeviceLimits(
           maxTextureDimension2D: maxDimension,
           maxGeometryBytes: maxGeometryBytes,
         ),
       );
}

typedef RendererFactory = Future<SceneRenderer> Function();

/// A per-viewport backend. Factories must return a fresh owned instance.
abstract interface class SceneRenderer {
  RendererCapabilities get capabilities;
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  });

  /// Waits for pending work and releases resources. Must be idempotent.
  Future<void> dispose();
}
