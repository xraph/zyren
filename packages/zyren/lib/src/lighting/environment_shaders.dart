part of '../resources/resource_scope.dart';

const _environmentSampling = '''
const PI: f32 = 3.141592653589793;
fn sequence(i: u32, count: u32) -> vec2<f32> {
  return vec2((f32(i) + .5) / f32(count), f32(reverseBits(i)) * 2.3283064365386963e-10);
}
fn ggx_half(xi: vec2<f32>, roughness: f32) -> vec3<f32> {
  let a = max(roughness * roughness, .002025);
  let cos_theta = sqrt((1. - xi.y) / max(1. + (a*a - 1.) * xi.y, 1e-8));
  let sin_theta = sqrt(max(0., 1. - cos_theta * cos_theta));
  let phi = 2. * PI * xi.x;
  return vec3(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}
''';

const _environmentConvolution =
    '''
$_environmentSampling
struct Options { roughness: f32, mode: u32, samples: u32, unused: u32 };
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var source_sampler: sampler;
@group(0) @binding(2) var output: texture_storage_2d<rgba16float, write>;
@group(0) @binding(3) var<uniform> options: Options;
fn direction(uv: vec2<f32>) -> vec3<f32> {
  let phi = (uv.x - .5) * 2. * PI;
  let theta = uv.y * PI;
  return vec3(cos(phi) * sin(theta), cos(theta), sin(phi) * sin(theta));
}
fn coordinates(n: vec3<f32>) -> vec2<f32> {
  return vec2(atan2(n.z, n.x) / (2. * PI) + .5, acos(clamp(n.y, -1., 1.)) / PI);
}
fn radiance(n: vec3<f32>, solid_angle: f32) -> vec3<f32> {
  let extent = vec2<f32>(textureDimensions(source));
  let texel_angle = 2. * PI * PI * max(sqrt(max(0., 1. - n.y*n.y)), 1e-4) / (extent.x * extent.y);
  let lod = clamp(.5 * log2(max(solid_angle / texel_angle, 1.)), 0., f32(textureNumLevels(source) - 1u));
  return textureSampleLevel(source, source_sampler, coordinates(n), lod).rgb;
}
@compute @workgroup_size(8, 8) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  let extent = textureDimensions(output);
  if (any(id.xy >= extent)) { return; }
  let n = direction((vec2<f32>(id.xy) + .5) / vec2<f32>(extent));
  if (options.mode == 1u && options.roughness == 0.) {
    let lod = max(0., log2(f32(textureDimensions(source).x) / f32(extent.x)));
    textureStore(output, vec2<i32>(id.xy), vec4(textureSampleLevel(source, source_sampler, coordinates(n), lod).rgb, 1.));
    return;
  }
  let up = select(vec3(0.,0.,1.), vec3(1.,0.,0.), abs(n.z) > .999);
  let tangent = normalize(cross(up, n));
  let basis = mat3x3<f32>(tangent, cross(n, tangent), n);
  var sum = vec3(0.);
  var weight = 0.;
  let a = max(options.roughness * options.roughness, .002025);
  for (var i = 0u; i < options.samples; i++) {
    let xi = sequence(i, options.samples);
    if (options.mode == 0u) {
      let phi = 2. * PI * xi.x;
      let l = basis * vec3(cos(phi) * sqrt(xi.y), sin(phi) * sqrt(xi.y), sqrt(1. - xi.y));
      let pdf = max(dot(n,l), 1e-6) / PI;
      sum += radiance(l, 1. / (f32(options.samples) * pdf));
      weight += 1.;
    } else {
      let h = basis * ggx_half(xi, options.roughness);
      let nh = max(dot(n,h), 1e-6);
      let l = normalize(2. * nh * h - n);
      let nl = max(dot(n,l), 0.);
      if (nl > 0.) {
        let denominator = nh * nh * (a*a - 1.) + 1.;
        let pdf = a*a / max(4. * PI * denominator * denominator, 1e-12);
        sum += radiance(l, 1. / (f32(options.samples) * pdf)) * nl;
        weight += nl;
      }
    }
  }
  textureStore(output, vec2<i32>(id.xy), vec4(sum / max(weight, 1e-6), 1.));
}
''';

// RG stores Schlick A/B; A+B is the correlated-Smith white directional albedo.
const _environmentBrdf =
    '''
$ggxEnergyWgsl
struct Options { roughness: f32, mode: u32, samples: u32, unused: u32 };
@group(0) @binding(0) var output: texture_storage_2d<rgba16float, write>;
@group(0) @binding(1) var<uniform> options: Options;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
  let extent = textureDimensions(output);
  if (any(id.xy >= extent)) { return; }
  let uv = vec2<f32>(id.xy) / vec2<f32>(extent - vec2(1u));
  textureStore(output,vec2<i32>(id.xy),vec4(ggx_energy_integral(uv.x,uv.y,options.samples),0.,1.));
}
''';
