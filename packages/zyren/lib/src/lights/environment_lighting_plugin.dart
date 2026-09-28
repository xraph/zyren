import 'dart:typed_data';
import '../plugins/engine.dart';
import '../rendering/capabilities.dart';
import '../resources/resource_scope.dart';
import '../resources/texture.dart';

/// Owned linear RGBA radiance in an equirectangular, Y-up image.
final class EnvironmentImage {
  final int width, height;
  final Float32List _pixels;
  EnvironmentImage._(this.width, this.height, this._pixels);
  factory EnvironmentImage({
    required int width,
    required int height,
    required Float32List pixels,
  }) {
    if (width < 1 ||
        height < 1 ||
        width > 2048 ||
        height > 1024 ||
        pixels.length != width * height * 4 ||
        pixels.any((v) => !v.isFinite || v < 0 || v > 65504)) {
      throw ArgumentError(
        'Environment images require bounded finite linear RGBA data.',
      );
    }
    return EnvironmentImage._(width, height, Float32List.fromList(pixels));
  }
  Uint8List get bytes => Uint8List.fromList(_pixels.buffer.asUint8List());
}

const environmentLighting = ServiceKey<EnvironmentMap>('zyren.environment');

/// Owns the source, convolution graph and lookup tables for one native device.
final class EnvironmentLightingPlugin extends ScenePlugin {
  final EnvironmentImage image;
  final int resolution, roughnessLevels, samples, brdfSize;
  final double intensity, rotation;
  EnvironmentLightingPlugin(
    this.image, {
    this.resolution = 32,
    this.roughnessLevels = 8,
    this.samples = 256,
    this.brdfSize = 64,
    this.intensity = 1,
    this.rotation = 0,
  });
  @override
  String get id => 'environment-lighting';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.renderGraphs,
    RenderFeature.compute,
    RenderFeature.floatTextures,
    RenderFeature.volumeTextures,
    RenderFeature.hdr,
  };
  @override
  Future<void> attach(PluginContext context) async {
    final source = await context.resources.createTexture(
      TextureDescriptor(
        label: 'environment source',
        width: image.width,
        height: image.height,
        format: TextureFormat.rgba32Float,
        usage: {TextureUsage.sampled, TextureUsage.copyDestination},
      ),
    );
    await context.resources.writeTexture(source, image.bytes);
    final result = await EnvironmentMap.generate(
      resources: context.resources,
      shaders: context.shaders,
      graphs: context.graphs,
      source: source,
      resolution: resolution,
      roughnessLevels: roughnessLevels,
      samples: samples,
      brdfSize: brdfSize,
    );
    final map = EnvironmentMap(
      irradiance: result.irradiance,
      specular: result.specular,
      brdf: result.brdf,
      intensity: intensity,
      rotation: rotation,
    );
    context.scope.keep(context.scene.addEnvironment(map));
    context.provide(environmentLighting, map);
    context.invalidate();
  }
}
