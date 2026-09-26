import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';

/// Adapts the alpha plugin engine to explicit backend outputs during migration.
class BackendRenderer implements SceneRenderer {
  final RenderBackend backend;
  FrameTime time = const FrameTime();
  FrameStats? stats;
  BackendRenderer(this.backend);
  @override
  RendererCapabilities get capabilities => RendererCapabilities(
    name: backend.capabilities.name,
    maxDimension: backend.capabilities.limits.maxTextureDimension2D,
    features: {
      for (final feature in backend.capabilities.features)
        switch (feature) {
          RenderFeature.indexedMeshes => RenderFeatures.indexedMeshes,
          RenderFeature.diffuseLighting => RenderFeatures.diffuseLighting,
          RenderFeature.unlitMaterials => RenderFeatures.unlitMaterials,
          RenderFeature.rgbaReadback => RenderFeatures.rgbaReadback,
          _ => feature.name,
        },
    },
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async {
    final output = await backend.render(
      FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(width, height),
        time: time,
      ),
    );
    stats = output.stats;
    return switch (output) {
      ReadbackOutput(:final image) => _frame(image),
      PresentedOutput() => throw SceneException(
        SceneIssue(
          operation: 'present',
          code: SceneIssueCodes.presentationUnavailable,
          message: 'The active presenter requires an explicit readback output.',
        ),
      ),
    };
  }

  RenderedFrame _frame(ImageData image) {
    if (image.format != PixelFormat.rgba8 ||
        image.colorSpace != ColorSpace.srgb) {
      throw SceneException(
        SceneIssue(
          operation: 'present',
          code: SceneIssueCodes.unsupportedFeature,
          message: 'The image presenter requires RGBA8 sRGB.',
        ),
      );
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

  @override
  Future<void> dispose() => backend.close();
}
