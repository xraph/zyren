struct Uniforms {
    mvp: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
    color_unlit: vec4<f32>,
    light_ambient: vec4<f32>,
    map_params: vec4<f32>,
};
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(1) @binding(0) var color_map: texture_2d<f32>;
@group(1) @binding(1) var color_sampler: sampler;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) uv: vec2<f32>,
};

@vertex fn vs_main(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> VertexOutput {
    var output: VertexOutput;
    output.position = uniforms.mvp * vec4<f32>(position, 1.0);
    output.normal = (uniforms.normal_matrix * vec4<f32>(normal, 0.0)).xyz;
    output.uv = vec2<f32>(0.0);
    return output;
}

@vertex fn vs_textured(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> VertexOutput {
    var output: VertexOutput;
    output.position = uniforms.mvp * vec4<f32>(position, 1.0);
    output.normal = (uniforms.normal_matrix * vec4<f32>(normal, 0.0)).xyz;
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    return output;
}

@fragment fn fs_textured(input: VertexOutput) -> @location(0) vec4<f32> {
    let diffuse = max(dot(normalize(input.normal), normalize(uniforms.light_ambient.xyz)), 0.0);
    let lighting = uniforms.light_ambient.w + (1.0 - uniforms.light_ambient.w) * diffuse;
    let strength = mix(lighting, 1.0, uniforms.color_unlit.w);
    let color = textureSample(color_map, color_sampler, input.uv);
    return vec4<f32>(color.rgb * uniforms.color_unlit.rgb * strength, 1.0);
}

@fragment fn fs_main(input: VertexOutput) -> @location(0) vec4<f32> {
    let diffuse = max(dot(normalize(input.normal), normalize(uniforms.light_ambient.xyz)), 0.0);
    let lighting = uniforms.light_ambient.w + (1.0 - uniforms.light_ambient.w) * diffuse;
    let strength = mix(lighting, 1.0, uniforms.color_unlit.w);
    return vec4<f32>(uniforms.color_unlit.rgb * strength, 1.0);
}
