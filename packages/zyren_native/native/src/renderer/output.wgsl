
struct ScreenUniforms {
  inverseViewProjection: mat4x4<f32>,
  viewport: vec4<f32>, // width, height, history valid, exposure
  output: vec4<f32>, // tone map, reserved
};
@group(0) @binding(0) var sceneColor: texture_2d<f32>;
@group(0) @binding(1) var sceneDepth: texture_depth_2d;
@group(0) @binding(2) var historyColor: texture_2d<f32>;
@group(0) @binding(3) var<uniform> screen: ScreenUniforms;
struct ScreenVertex {
  @builtin(position) position: vec4<f32>,
  @location(0) uv: vec2<f32>,
};
@vertex fn vertex(@builtin(vertex_index) index: u32) -> ScreenVertex {
  let uv = vec2<f32>(f32((index << 1u) & 2u), f32(index & 2u));
  var v: ScreenVertex;
  v.position = vec4<f32>(uv * vec2<f32>(2.0, -2.0) + vec2<f32>(-1.0, 1.0), 0.0, 1.0);
  v.uv = uv;
  return v;
}

fn toSrgb(x: vec3<f32>) -> vec3<f32> {
 return select(1.055 * pow(x, vec3<f32>(1.0/2.4)) - .055, x * 12.92, x <= vec3<f32>(.0031308));
}
fn fromSrgb(x: vec3<f32>) -> vec3<f32> {
 return select(pow((x + .055) / 1.055, vec3<f32>(2.4)), x / 12.92, x <= vec3<f32>(.04045));
}
@fragment fn fragment(v: ScreenVertex) -> @location(0) vec4<f32> {
 let c = textureLoad(sceneColor, vec2<i32>(v.position.xy), 0);
 let alpha = clamp(c.a, 0., 1.);
 var rgb = clamp(c.rgb / max(alpha, 1e-6) * screen.viewport.w, vec3<f32>(0.), vec3<f32>(65504.));
 if (screen.output.x == 1.) { rgb = rgb / (vec3<f32>(1.) + rgb); }
 if (screen.output.x == 2.) { rgb = clamp((rgb * (2.51 * rgb + .03)) / (rgb * (2.43 * rgb + .59) + .14), vec3<f32>(0.), vec3<f32>(1.)); }
 let encoded = toSrgb(clamp(rgb, vec3<f32>(0.), vec3<f32>(1.))) * alpha;
 return vec4<f32>(select(encoded, fromSrgb(encoded), screen.output.y == 1.), alpha);
}
