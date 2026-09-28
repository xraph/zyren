const effectsWgsl = '''
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var<uniform> parameters: vec4<f32>;

@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}

@fragment fn grade(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  let color = textureLoad(source, vec2<i32>(pixel.xy), 0);
  let luminance = dot(color.rgb, vec3(.2126, .7152, .0722));
  let saturated = mix(vec3(luminance), color.rgb, parameters.y);
  return vec4(clamp(saturated * parameters.x, vec3(0.), vec3(1.)), color.a);
}

@fragment fn vignette(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  let color = textureLoad(source, vec2<i32>(pixel.xy), 0);
  let uv = pixel.xy / vec2<f32>(textureDimensions(source)) - vec2(.5);
  let factor = 1. - parameters.z * clamp(2. * dot(uv, uv), 0., 1.);
  return vec4(color.rgb * factor, color.a);
}
''';
