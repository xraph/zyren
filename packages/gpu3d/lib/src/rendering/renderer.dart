import 'dart:typed_data';
import 'capabilities.dart';
import '../scene/scene.dart';

/// Tightly packed, top-down RGBA8 pixels. The consumer owns this buffer.
class RenderedFrame {
  final Uint8List pixels;
  final int width, height;
  const RenderedFrame(this.pixels, this.width, this.height);
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
