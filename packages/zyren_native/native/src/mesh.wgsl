struct Uniforms {
    mvp: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
    color_unlit: vec4<f32>,
    light_ambient: vec4<f32>,
    map_params: vec4<f32>,
    view_projection: mat4x4<f32>,
    model: mat4x4<f32>,
    primitive: vec4<f32>,
    viewport: vec4<f32>,
    inverse_view_projection: mat4x4<f32>,
    clipping_planes: array<vec4<f32>,6>,
    clipping: vec4<f32>,
};
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
fn section_clip(point: vec3<f32>) {
    for (var i = 0u; i < u32(uniforms.clipping.x); i++) {
        if dot(uniforms.clipping_planes[i], vec4<f32>(point, 1.)) < 0. { discard; }
    }
}
@group(1) @binding(0) var color_map: texture_2d<f32>;
@group(1) @binding(1) var color_sampler: sampler;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) point: vec3<f32>,
};

@vertex fn vs_main(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> VertexOutput {
    var output: VertexOutput;
    output.point = (uniforms.model * vec4<f32>(position, 1.)).xyz;
    output.position = uniforms.mvp * vec4<f32>(position, 1.0);
    output.normal = (uniforms.normal_matrix * vec4<f32>(normal, 0.0)).xyz;
    output.uv = vec2<f32>(0.0);
    return output;
}

@vertex fn vs_textured(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> VertexOutput {
    var output: VertexOutput;
    output.point = (uniforms.model * vec4<f32>(position, 1.)).xyz;
    output.position = uniforms.mvp * vec4<f32>(position, 1.0);
    output.normal = (uniforms.normal_matrix * vec4<f32>(normal, 0.0)).xyz;
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    return output;
}

fn shade(normal: vec3<f32>, sample_color: vec4<f32>, point: vec3<f32>) -> vec4<f32> {
    section_clip(point);
    let diffuse = max(dot(normalize(normal), normalize(uniforms.light_ambient.xyz)), 0.0);
    let lighting = uniforms.light_ambient.w + (1.0 - uniforms.light_ambient.w) * diffuse;
    let strength = mix(lighting, 1.0, uniforms.color_unlit.w);
    let alpha = sample_color.a * uniforms.map_params.y;
    let mode = uniforms.map_params.w;
    if mode > 0.5 && mode < 1.5 && alpha < uniforms.map_params.z { discard; }
    return vec4<f32>(sample_color.rgb * uniforms.color_unlit.rgb * strength,
        select(1.0, alpha, mode > 1.5));
}

@fragment fn fs_textured(input: VertexOutput, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    return shade(select(-input.normal, input.normal, front), textureSample(color_map, color_sampler, input.uv), input.point);
}

@fragment fn fs_main(input: VertexOutput, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    return shade(select(-input.normal, input.normal, front), vec4<f32>(1.0), input.point);
}

@vertex fn vs_main_instanced(@location(0) position:vec3<f32>, @location(1) normal:vec3<f32>, i:InstanceTransform)->VertexOutput {
 return VertexOutput(uniforms.view_projection*instanceModel(i)*vec4<f32>(position,1.),instanceNormal(i)*normal,vec2<f32>(0.),(instanceModel(i)*vec4<f32>(position,1.)).xyz);
}
@vertex fn vs_textured_instanced(@location(0) position:vec3<f32>, @location(1) normal:vec3<f32>, @location(2) uv0:vec2<f32>, @location(3) uv1:vec2<f32>, i:InstanceTransform)->VertexOutput {
 return VertexOutput(uniforms.view_projection*instanceModel(i)*vec4<f32>(position,1.),instanceNormal(i)*normal,select(uv0,uv1,uniforms.map_params.x>.5),(instanceModel(i)*vec4<f32>(position,1.)).xyz);
}
