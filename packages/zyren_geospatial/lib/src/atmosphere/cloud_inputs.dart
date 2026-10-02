import 'package:zyren/zyren.dart';

/// Cloud screen outputs use top-left UVs and linear values. Color is premultiplied
/// radiance. Depth/velocity/shadow stores front depth in metres, UV motion in YZ,
/// and shadow length in kilometres in W. Transmittance uses its first channel.
final class AtmosphereCloudInputs {
  final GpuResource<Texture> color, depthVelocityShadow, transmittance;
  AtmosphereCloudInputs({
    required this.color,
    required this.depthVelocityShadow,
    required this.transmittance,
  }) {
    for (final texture in [color, depthVelocityShadow, transmittance]) {
      final d = texture.descriptor as TextureDescriptor;
      if (d.dimension != TextureDimension.d2 ||
          !d.usage.contains(TextureUsage.sampled) ||
          d.format == TextureFormat.rgba8UnormSrgb) {
        throw ArgumentError(
          'Atmosphere cloud inputs require sampled linear 2D textures.',
        );
      }
    }
    for (final texture in [color, depthVelocityShadow]) {
      if ((texture.descriptor as TextureDescriptor).format ==
          TextureFormat.r32Float) {
        throw ArgumentError(
          'Cloud color and depth/velocity/shadow need four channels.',
        );
      }
    }
    if ((depthVelocityShadow.descriptor as TextureDescriptor).format ==
        TextureFormat.rgba8Unorm) {
      throw ArgumentError('Cloud depth/velocity/shadow needs a float texture.');
    }
  }
}

final class RetainedAtmosphereCloudInputs {
  final GpuScope scope;
  final AtmosphereCloudInputs value;
  RetainedAtmosphereCloudInputs._(this.scope, this.value);
  static Future<RetainedAtmosphereCloudInputs> retain(
    GpuScope parent,
    AtmosphereCloudInputs inputs,
  ) async {
    final scope = parent.createChild(label: 'atmosphere cloud inputs');
    try {
      return RetainedAtmosphereCloudInputs._(
        scope,
        AtmosphereCloudInputs(
          color: await scope.resources.retain(inputs.color),
          depthVelocityShadow: await scope.resources.retain(
            inputs.depthVelocityShadow,
          ),
          transmittance: await scope.resources.retain(inputs.transmittance),
        ),
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }
}
