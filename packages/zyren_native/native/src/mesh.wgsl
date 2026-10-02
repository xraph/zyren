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
    pbr_params: vec4<f32>,
    emissive: vec4<f32>,
    pbr_maps: vec4<u32>,
    pbr_factors: vec4<f32>,
    physical: array<vec4<f32>, 4>,
    transmission: array<vec4<f32>,2>,
    optical: array<vec4<f32>,2>,
    capture_projection: mat4x4<f32>,
    clipping_planes: array<vec4<f32>, 6>,
    clipping: vec4<f32>,
    inverse_view_projection: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(1) @binding(0) var color_map: texture_2d<f32>;
@group(1) @binding(1) var color_sampler: sampler;

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) relative_position: vec3<f32>,
    @location(3) uv0: vec2<f32>,
    @location(4) uv1: vec2<f32>,
    @location(5) tangent: vec4<f32>,
    @location(6) color: vec4<f32>,
    @location(7) @interpolate(flat) orientation: f32,
    @location(8) @interpolate(flat) world_scale: vec3<f32>,
};

fn mesh_vertex(position: vec3<f32>, normal: vec3<f32>) -> VertexOutput {
    var output: VertexOutput;
    output.color = vec4(1.);
    output.orientation = 1.;
    output.world_scale=vec3(length(uniforms.model[0].xyz),length(uniforms.model[1].xyz),length(uniforms.model[2].xyz));
    output.position = uniforms.mvp * vec4<f32>(position, 1.0);
    output.relative_position = (uniforms.model * vec4<f32>(position, 1.0)).xyz;
    output.normal = (uniforms.normal_matrix * vec4<f32>(normal, 0.0)).xyz;
    output.uv = vec2<f32>(0.0);
    return output;
}

@vertex fn vs_main(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> VertexOutput {
    return mesh_vertex(position, normal);
}
@vertex fn vs_colored(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = mesh_vertex(position, normal);
    output.color = color;
    return output;
}

fn textured_vertex(position: vec3<f32>, normal: vec3<f32>, uv0: vec2<f32>, uv1: vec2<f32>) -> VertexOutput {
    var output: VertexOutput;
    output.color = vec4(1.);
    output.orientation = 1.;
    output.world_scale=vec3(length(uniforms.model[0].xyz),length(uniforms.model[1].xyz),length(uniforms.model[2].xyz));
    output.position = uniforms.mvp * vec4<f32>(position, 1.0);
    output.relative_position = (uniforms.model * vec4<f32>(position, 1.0)).xyz;
    output.normal = (uniforms.normal_matrix * vec4<f32>(normal, 0.0)).xyz;
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    return output;
}

@vertex fn vs_textured(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> VertexOutput {
    return textured_vertex(position, normal, uv0, uv1);
}
@vertex fn vs_standard_tangent(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>) -> VertexOutput {
    var output = textured_vertex(position, normal, uv0, uv1);
    output.tangent = vec4((uniforms.model * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z);
    return output;
}
@vertex fn vs_textured_colored(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = textured_vertex(position, normal, uv0, uv1);
    output.color = color;
    return output;
}
@vertex fn vs_standard_tangent_colored(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = textured_vertex(position, normal, uv0, uv1);
    output.color = color;
    output.tangent = vec4((uniforms.model * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z);
    return output;
}
fn shade(normal: vec3<f32>, sample_color: vec4<f32>) -> vec4<f32> {
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
    clip_fragment(input.relative_position, input.position.xy);
    return shade(select(-input.normal, input.normal, material_front(front, input.orientation)), textureSample(color_map, color_sampler, input.uv) * input.color);
}

@fragment fn fs_main(input: VertexOutput, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    clip_fragment(input.relative_position, input.position.xy);
    return shade(select(-input.normal, input.normal, material_front(front, input.orientation)), input.color);
}

struct InstanceInput {
    @location(6) model0: vec4<f32>,
    @location(7) model1: vec4<f32>,
    @location(8) model2: vec4<f32>,
    @location(9) model3: vec4<f32>,
    @location(10) normal0: vec4<f32>,
    @location(11) normal1: vec4<f32>,
    @location(12) normal2: vec4<f32>,
    @location(13) color: vec3<f32>,
};
fn instance_matrix(instance: InstanceInput) -> mat4x4<f32> {
    return mat4x4(instance.model0, instance.model1, instance.model2, instance.model3);
}
fn instance_vertex(position: vec3<f32>, normal: vec3<f32>, instance: InstanceInput) -> VertexOutput {
    let local = instance_matrix(instance) * vec4(position, 1.);
    let n = mat3x3(instance.normal0.xyz, instance.normal1.xyz, instance.normal2.xyz) * normal;
    var output = mesh_vertex(local.xyz, n);
    output.orientation = instance.normal0.w;
    let world=uniforms.model*instance_matrix(instance);
    output.world_scale=vec3(length(world[0].xyz),length(world[1].xyz),length(world[2].xyz));
    output.color = vec4(instance.color, 1.);
    return output;
}
fn material_front(front: bool, orientation: f32) -> bool {
    let oriented = front == (orientation > 0.);
    if (uniforms.viewport.z == 1. && !oriented) || (uniforms.viewport.z == 2. && oriented) { discard; }
    return oriented;
}

@vertex fn vs_instance_main(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    return output;
}

@vertex fn vs_instance_colored(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    output.color *= color;
    return output;
}

@vertex fn vs_instance_textured(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    return output;
}

@vertex fn vs_instance_textured_colored(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    output.color *= color;
    return output;
}

@vertex fn vs_instance_standard_tangent(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    output.tangent = vec4((uniforms.model * instance_matrix(instance) * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z * instance.normal0.w);
    return output;
}

@vertex fn vs_instance_standard_tangent_colored(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    output.tangent = vec4((uniforms.model * instance_matrix(instance) * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z * instance.normal0.w);
    output.color *= color;
    return output;
}

@vertex fn vs_standard_tangent_unmapped(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(4) tangent: vec4<f32>) -> VertexOutput {
    var output = textured_vertex(position, normal, vec2(0.), vec2(0.));
    output.tangent = vec4((uniforms.model * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z);
    return output;
}
@vertex fn vs_standard_tangent_colored_unmapped(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(4) tangent: vec4<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = textured_vertex(position, normal, vec2(0.), vec2(0.));
    output.color = color;
    output.tangent = vec4((uniforms.model * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z);
    return output;
}
@vertex fn vs_instance_standard_tangent_unmapped(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(4) tangent: vec4<f32>) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    output.tangent = vec4((uniforms.model * instance_matrix(instance) * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z * instance.normal0.w);
    return output;
}
@vertex fn vs_instance_standard_tangent_colored_unmapped(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(4) tangent: vec4<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    var output = instance_vertex(position, normal, instance);
    output.tangent = vec4((uniforms.model * instance_matrix(instance) * vec4(tangent.xyz, 0.)).xyz, tangent.w * uniforms.pbr_factors.z * instance.normal0.w);
    output.color *= color;
    return output;
}

fn clip_fragment(position: vec3<f32>, pixel: vec2<f32>) {
    fragment_coverage(pixel, uniforms.clipping.yz);
    for (var i=0u; i<u32(uniforms.clipping.x); i++) {
        if dot(uniforms.clipping_planes[i],vec4(position,1.)) < 0. { discard; }
    }
}
