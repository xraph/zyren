@group(0) @binding(0) var color: texture_2d<f32>;
@group(0) @binding(1) var depth: texture_depth_2d;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4(p * 2. - 1., 0., 1.);
}
struct Output { @location(0) color: vec4<f32>, @builtin(frag_depth) depth: f32 }
@fragment fn fragment(@builtin(position) p: vec4<f32>) -> Output {
    return Output(textureLoad(color, vec2<i32>(p.xy), 0), textureLoad(depth, vec2<i32>(p.xy), 0));
}
