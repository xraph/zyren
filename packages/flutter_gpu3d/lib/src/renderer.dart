import 'dart:typed_data';
import 'scene.dart';

/// Tightly packed, top-down RGBA8 pixels. The consumer owns this buffer.
class RenderedFrame {
  final Uint8List pixels;
  final int width, height;
  const RenderedFrame(this.pixels, this.width, this.height);
}

/// Stable feature identifiers that plugins can require before allocating work.
abstract final class RenderFeatures {
  static const indexedMeshes = 'indexed-meshes';
  static const diffuseLighting = 'diffuse-lighting';
  static const unlitMaterials = 'unlit-materials';
  static const rgbaReadback = 'rgba-readback';
}

class RendererCapabilities {
  final String name;
  final Set<String> features;
  final int maxDimension;
  RendererCapabilities({
    required this.name,
    required Set<String> features,
    required this.maxDimension,
  }) : features = Set.unmodifiable(features) {
    if (maxDimension < 1) {
      throw ArgumentError.value(maxDimension, 'maxDimension');
    }
  }
}

typedef RendererFactory = Future<SceneRenderer> Function();

/// A per-viewport backend. Factories must return a fresh owned instance.
abstract interface class SceneRenderer {
  RendererCapabilities get capabilities;
  Future<RenderedFrame> render(
    Scene scene,
    PerspectiveCamera camera, {
    required int width,
    required int height,
  });

  /// Waits for pending work and releases resources. Must be idempotent.
  Future<void> dispose();
}
