struct DepthUniform { mvp: mat4x4<f32>, params: vec4<f32> };
@group(0) @binding(0) var<uniform> depth: DepthUniform;
@group(1) @binding(0) var alpha_map: texture_2d<f32>;
@group(1) @binding(1) var alpha_sampler: sampler;
struct DepthOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};
@vertex fn vs_depth(@location(0) position: vec3<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.position = depth.mvp * vec4(position, 1.);
    output.uv = vec2(0.);
    return output;
}
@vertex fn vs_depth_textured(@location(0) position: vec3<f32>, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.position = depth.mvp * vec4(position, 1.);
    output.uv = select(uv0, uv1, depth.params.w > .5);
    return output;
}
@fragment fn fs_depth() {
    if (depth.params.z > .5 && depth.params.x < depth.params.y) { discard; }
}
@fragment fn fs_depth_textured(input: DepthOutput) {
    let alpha = textureSample(alpha_map, alpha_sampler, input.uv).a * depth.params.x;
    if (depth.params.z > .5 && alpha < depth.params.y) { discard; }
}
