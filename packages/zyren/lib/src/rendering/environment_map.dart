part of '../resources/resource_scope.dart';

/// Adapter-only encoding for generation-checked sampled resource handles.
abstract interface class EnvironmentDevice implements ResourceDevice {
  Uint8List encodeResourceKey(Object key);
}

/// Linear diffuse irradiance, GGX radiance slices and a split-sum BRDF table.
/// Retain all three textures in a surviving scope before closing their owner.
/// Caller-supplied BRDF R/G store correlated-Smith Schlick A/B. Texel (x,y)
/// represents NdotV=x/(width-1), roughness=y/(height-1), including endpoints.
/// Sampling remaps those coordinates to texel centers; a one-texel axis uses .5.
final class VolumeEnvironmentMap {
  final GpuResource<Texture> irradiance, specular, brdf;
  final double intensity, rotation;
  bool get isClosed =>
      irradiance.isClosed || specular.isClosed || brdf.isClosed;
  VolumeEnvironmentMap({
    required this.irradiance,
    required this.specular,
    required this.brdf,
    this.intensity = 1,
    this.rotation = 0,
  }) {
    if (!intensity.isFinite ||
        intensity < 0 ||
        intensity > 65504 ||
        !rotation.isFinite) {
      throw ArgumentError('Invalid environment intensity or rotation.');
    }
    final device = irradiance._scope._device;
    for (final (index, texture) in [irradiance, specular, brdf].indexed) {
      final d = texture.descriptor as TextureDescriptor;
      if (texture.isClosed) {
        throw StateError('Environment resource owner has closed.');
      }
      if (!identical(texture._scope._device, device) ||
          d.format != TextureFormat.rgba16Float ||
          !d.usage.contains(TextureUsage.sampled) ||
          d.mipLevels != 1 ||
          d.dimension !=
              (index == 1 ? TextureDimension.d3 : TextureDimension.d2)) {
        throw ArgumentError(
          'Environment textures must share a device and the linear float layout.',
        );
      }
    }
    if ((specular.descriptor as TextureDescriptor).depth < 2) {
      throw ArgumentError('Environment needs at least two roughness slices.');
    }
  }
  List<Uint8List> encodeForDevice(EnvironmentDevice device) => [
    for (final texture in [irradiance, specular, brdf])
      _encode(texture, device),
  ];
  Uint8List _encode(GpuResource<Texture> texture, EnvironmentDevice device) {
    if (texture.isClosed) {
      throw StateError('Environment resource owner has closed.');
    }
    if (!identical(texture._scope._device, device)) {
      throw ArgumentError('Environment belongs to another device.');
    }
    final key = device.encodeResourceKey(texture._key);
    if (key.length != 32) {
      throw StateError('Invalid environment resource token.');
    }
    return key;
  }

  /// Computes an equirectangular source using the caller's public graph scopes.
  /// Publish the returned map only after this future succeeds. Failed candidates
  /// remain owned by the supplied resource scope and must be closed by its owner.
  static Future<VolumeEnvironmentMap> generate({
    required ResourceScope resources,
    required ShaderCompiler shaders,
    required GraphCompiler graphs,
    required GpuResource<Texture> source,
    int resolution = 32,
    int roughnessLevels = 8,
    int samples = 256,
    int brdfSize = 64,
  }) async {
    final d = source.descriptor as TextureDescriptor;
    if (d.dimension != TextureDimension.d2 ||
        !d.usage.contains(TextureUsage.sampled) ||
        !identical(source._scope._device, resources._device) ||
        source.isClosed ||
        resolution < 4 ||
        resolution > 128 ||
        roughnessLevels < 2 ||
        roughnessLevels > 16 ||
        samples < 32 ||
        samples > 1024 ||
        brdfSize < 8 ||
        brdfSize > 128 ||
        (resolution * resolution * 2 * (roughnessLevels + 1) +
                    brdfSize * brdfSize) *
                samples >
            64000000) {
      throw ArgumentError('Invalid environment source or convolution budget.');
    }
    Future<GpuResource<Texture>> target(
      String label,
      int w,
      int h, {
      int depth = 1,
    }) => resources.createTexture(
      TextureDescriptor(
        label: label,
        width: w,
        height: h,
        depth: depth,
        dimension: depth == 1 ? TextureDimension.d2 : TextureDimension.d3,
        format: TextureFormat.rgba16Float,
        usage: {
          TextureUsage.storage,
          TextureUsage.sampled,
          TextureUsage.copySource,
        },
      ),
    );
    final irradiance = await target(
      'environment irradiance',
      resolution * 2,
      resolution,
    );
    final specular = await target(
      'environment GGX',
      resolution * 2,
      resolution,
      depth: roughnessLevels,
    );
    final brdf = await target('environment BRDF', brdfSize, brdfSize);
    final passes = <ComputePassDescriptor>[];
    for (final entry in [
      (irradiance, _irradianceWgsl),
      (specular, _specularWgsl),
      (brdf, _brdfWgsl),
    ]) {
      final output = entry.$1, out = entry.$1.descriptor as TextureDescriptor;
      final program = await shaders.compile(
        ShaderSource.wgsl(
          'const SAMPLES: u32 = ${samples}u;\n$_environmentCommonWgsl\n${entry.$2}',
          label: output.label,
        ),
      );
      final usesSource = !identical(output, brdf);
      passes.add(
        ComputePassDescriptor(
          name: output.label,
          program: program,
          bindings: ShaderBindings([
            if (usesSource) TextureBinding.sampled(0, source),
            TextureBinding.storage(1, output),
          ]),
          reads: usesSource ? [source] : [],
          writes: [output],
          workgroups: Workgroups(
            (out.width + 7) ~/ 8,
            (out.height + 7) ~/ 8,
            out.depth,
          ),
        ),
      );
    }
    final graph = await graphs.compile(
      GraphDescription(
        label: 'environment convolution',
        passes: passes,
        inputs: [source],
      ),
    );
    await graph.execute();
    return VolumeEnvironmentMap(
      irradiance: irradiance,
      specular: specular,
      brdf: brdf,
    );
  }
}
