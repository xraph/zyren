@group(0) @binding(0) var source: texture_2d<f32>;
struct Parameters { exposure: vec4<f32> };
@group(0) @binding(1) var<uniform> parameters: Parameters;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}
fn encode_srgb(rgb: vec3<f32>) -> vec3<f32> {
  return select(1.055 * pow(max(rgb, vec3(0.)), vec3(1. / 2.4)) - .055,
                12.92 * rgb, rgb <= vec3(.0031308));
}
fn decode_srgb(rgb: vec3<f32>) -> vec3<f32> {
  return select(pow(max((rgb + .055) / 1.055, vec3(0.)), vec3(2.4)),
                rgb / 12.92, rgb <= vec3(.04045));
}
// ACES fit and viewing exposure follow Three.js. See THIRD_PARTY_NOTICES.md.
fn tone_map(rgb: vec3<f32>) -> vec3<f32> {
  var c = clamp(rgb, vec3(0.), vec3(65504.)) * parameters.exposure.x;
  if (__CURVE__ == 1u) { return c / (vec3(1.) + c); }
  if (__CURVE__ == 2u) {
    let to_ap1 = mat3x3<f32>(vec3(.59719,.07600,.02840),
      vec3(.35458,.90834,.13383), vec3(.04823,.01566,.83777));
    let to_srgb = mat3x3<f32>(vec3(1.60475,-.10208,-.00327),
      vec3(-.53108,1.10813,-.07276), vec3(-.07367,-.00605,1.07602));
    c = to_ap1 * (c / .6);
    c = (c * (c + .0245786) - .000090537) / (c * (.983729 * c + .4329510) + .238081);
    c = to_srgb * c;
  }
  return clamp(c, vec3(0.), vec3(1.));
}
@fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  var color = textureLoad(source, vec2<i32>(pixel.xy), 0);
  if (__UNASSOCIATE__) {
    color = vec4(select(vec3(0.), color.rgb / max(color.a, 1e-8), color.a > 0.), color.a);
  }
  if (__HDR__) { color = vec4(tone_map(color.rgb), color.a); }
  if (__PREMULTIPLY__) {
    if (__SRGB__) {
      color = vec4(decode_srgb(encode_srgb(color.rgb) * color.a), color.a);
    } else {
      color = vec4(color.rgb * color.a, color.a);
    }
  }
  return color;
}
