struct DepthUniform { mvp: mat4x4<f32>, params: vec4<f32>, side: vec4<f32>, model: mat4x4<f32>, clipping_planes: array<vec4<f32>,6>, clipping: vec4<f32> };
@group(0) @binding(0) var<uniform> depth: DepthUniform;
@group(1) @binding(0) var alpha_map: texture_2d<f32>;
@group(1) @binding(1) var alpha_sampler: sampler;
struct DepthOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) alpha: f32,
    @location(3) relative_position: vec3<f32>,
    @location(2) @interpolate(flat) orientation: f32,
};
@vertex fn vs_depth(@location(0) position: vec3<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.orientation = 1.;
    output.alpha = 1.;
    output.position = depth.mvp * vec4(position, 1.);
    output.relative_position = (depth.model * vec4(position, 1.)).xyz;
    output.uv = vec2(0.);
    return output;
}
@vertex fn vs_depth_textured(@location(0) position: vec3<f32>, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.orientation = 1.;
    output.alpha = 1.;
    output.position = depth.mvp * vec4(position, 1.);
    output.relative_position = (depth.model * vec4(position, 1.)).xyz;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    return output;
}
@fragment fn fs_depth(input: DepthOutput, @builtin(front_facing) front: bool) {
    depth_front(front, input.orientation);
    fragment_coverage(input.position.xy, depth.clipping.yz);
    for (var i=0u; i<u32(depth.clipping.x); i++) {
        if dot(depth.clipping_planes[i], vec4(input.relative_position,1.)) < 0. { discard; }
    }
    if (depth.params.z > .5 && depth.params.x * input.alpha < depth.params.y) { discard; }
}
@fragment fn fs_depth_textured(input: DepthOutput, @builtin(front_facing) front: bool) {
    depth_front(front, input.orientation);
    fragment_coverage(input.position.xy, depth.clipping.yz);
    for (var i=0u; i<u32(depth.clipping.x); i++) {
        if dot(depth.clipping_planes[i], vec4(input.relative_position,1.)) < 0. { discard; }
    }
    let alpha = textureSample(alpha_map, alpha_sampler, input.uv).a * depth.params.x * input.alpha;
    if (depth.params.z > .5 && alpha < depth.params.y) { discard; }
}

@vertex fn vs_depth_colored(@location(0) position: vec3<f32>, @location(5) color: vec4<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.orientation = 1.;
    output.position = depth.mvp * vec4(position, 1.);
    output.relative_position = (depth.model * vec4(position, 1.)).xyz;
    output.alpha = color.a;
    return output;
}
@vertex fn vs_depth_textured_colored(@location(0) position: vec3<f32>, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.orientation = 1.;
    output.position = depth.mvp * vec4(position, 1.);
    output.relative_position = (depth.model * vec4(position, 1.)).xyz;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    output.alpha = color.a;
    return output;
}

struct DepthInstance {
    @location(6) model0: vec4<f32>, @location(7) model1: vec4<f32>,
    @location(8) model2: vec4<f32>, @location(9) model3: vec4<f32>,
    @location(10) normal0: vec4<f32>,
};
fn depth_front(front: bool, orientation: f32) {
    let oriented = front == (orientation > 0.);
    if (depth.side.x == 1. && !oriented) || (depth.side.x == 2. && oriented) { discard; }
}

@vertex fn vs_instance_depth(@location(0) position: vec3<f32>, instance: DepthInstance) -> DepthOutput {
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = 1.;
    return output;
}

@vertex fn vs_instance_depth_textured(@location(0) position: vec3<f32>, instance: DepthInstance, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = 1.;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    return output;
}

@vertex fn vs_instance_depth_colored(@location(0) position: vec3<f32>, instance: DepthInstance, @location(5) color: vec4<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = color.a;
    return output;
}

@vertex fn vs_instance_depth_textured_colored(@location(0) position: vec3<f32>, instance: DepthInstance, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> DepthOutput {
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = color.a;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    return output;
}
