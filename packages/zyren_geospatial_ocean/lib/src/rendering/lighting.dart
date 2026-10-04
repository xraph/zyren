import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'optics.dart';

/// Directions use ECEF, matching fixed wave charts. RGB values are linear HDR.
/// Supply atmosphere tables or a convolved native environment for scene lighting;
/// the standalone sky/ground colors are an explicit hemispherical approximation.
final class OceanLighting {
  final Vec3 sunDirectionEcef, sunIrradiance, skyRadiance, groundRadiance;
  final AtmosphereLuts? atmosphere;
  final VolumeEnvironmentMap? environment;
  OceanLighting({
    this.sunDirectionEcef = const Vec3(1, 0, 1),
    this.sunIrradiance = const Vec3(4, 3.8, 3.5),
    this.skyRadiance = const Vec3(.15, .3, .5),
    this.groundRadiance = const Vec3(.015, .02, .025),
    this.atmosphere,
    this.environment,
  }) {
    if (!sunDirectionEcef.isFinite ||
        sunDirectionEcef.length2 < 1e-20 ||
        !sunDirectionEcef.length2.isFinite) {
      throw ArgumentError('A finite nonzero sunlight direction is required.');
    }
    for (final v in [sunIrradiance, skyRadiance, groundRadiance]) {
      validateOceanRadiance(v, 'Ocean lighting');
    }
    if (atmosphere != null && environment != null) {
      throw ArgumentError('Select one environment lighting source.');
    }
    if ((atmosphere?.isClosed ?? false) || (environment?.isClosed ?? false)) {
      throw StateError('Ocean lighting resources have closed.');
    }
  }

  /// Reuses the shared atmosphere's precomputed lighting, including night and
  /// horizon attenuation. The full LUT option additionally supplies directional
  /// reflected sky radiance in the native water shader.
  factory OceanLighting.fromAtmosphereSample(
    AtmosphereLightSample sample, {
    required Vec3 sunDirectionEcef,
    AtmosphereLuts? atmosphere,
  }) => OceanLighting(
    sunDirectionEcef: sunDirectionEcef,
    sunIrradiance: sample.sunIrradiance,
    skyRadiance: sample.skyIrradiance / math.pi,
    atmosphere: atmosphere,
  );
}

/// Scope-retained irradiance inputs shared by underwater scattering and caustic
/// receivers. Functions accept ECEF up/sun directions and linear fallback values.
final class OceanMediumLighting {
  final String wgsl;
  final List<ShaderBinding> bindings;
  OceanMediumLighting._(this.wgsl, Iterable<ShaderBinding> bindings)
    : bindings = List.unmodifiable(bindings);

  Future<OceanMediumLighting> retain(GpuScope owner) async {
    final retained = <ShaderBinding>[];
    for (final binding in bindings) {
      if (binding is TextureBinding) {
        retained.add(
          TextureBinding.sampled(
            binding.binding,
            await owner.resources.retain(binding.resource),
            group: binding.group,
          ),
        );
      } else {
        retained.add(binding);
      }
    }
    return OceanMediumLighting._(wgsl, retained);
  }

  static Future<OceanMediumLighting> create(
    GpuScope owner,
    OceanLighting lighting,
  ) async {
    if (lighting.atmosphere case final atmosphere?) {
      final library = atmosphere.shader(group: 2);
      final result = OceanMediumLighting._(
        '''${library.source}fn oceanMediumSky(up:vec3<f32>,sun:vec3<f32>,fallback:vec3<f32>,environment:vec2<f32>)->vec3<f32>{
 return atmosphereSkyIrradiance(up*BOTTOM,up,sun)*.31830988618;
}
fn oceanMediumSun(up:vec3<f32>,sun:vec3<f32>,fallback:vec3<f32>)->vec3<f32>{
 return atmosphereSunIrradiance(up*BOTTOM,sun,sun);
}
''',
        library.bindings.entries,
      );
      return result.retain(owner);
    }
    if (lighting.environment case final environment?) {
      final result = OceanMediumLighting._(
        '''
@group(2) @binding(0) var oceanMediumIrradiance:texture_2d<f32>;
@group(2) @binding(1) var oceanMediumSampler:sampler;
fn oceanMediumSky(up:vec3<f32>,sun:vec3<f32>,fallback:vec3<f32>,environment:vec2<f32>)->vec3<f32>{
 let uv=vec2(fract(atan2(up.z,up.x)/6.28318530718+.5+environment.y/6.28318530718),acos(clamp(up.y,-1.,1.))/3.14159265359);
 return textureSampleLevel(oceanMediumIrradiance,oceanMediumSampler,uv,0.).rgb*environment.x*.31830988618;
}
fn oceanMediumSun(up:vec3<f32>,sun:vec3<f32>,fallback:vec3<f32>)->vec3<f32>{return fallback;}
''',
        [
          TextureBinding.sampled(0, environment.irradiance, group: 2),
          SamplerBinding(
            1,
            group: 2,
            sampler: const SamplerDescriptor(
              wrapU: TextureWrap.repeat,
              wrapV: TextureWrap.clampToEdge,
              minFilter: TextureFilter.linear,
              magFilter: TextureFilter.linear,
            ),
          ),
        ],
      );
      return result.retain(owner);
    }
    return OceanMediumLighting._('''
fn oceanMediumSky(up:vec3<f32>,sun:vec3<f32>,fallback:vec3<f32>,environment:vec2<f32>)->vec3<f32>{return fallback;}
fn oceanMediumSun(up:vec3<f32>,sun:vec3<f32>,fallback:vec3<f32>)->vec3<f32>{return fallback;}
''', const []);
  }
}
