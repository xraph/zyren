@vertex fn deformed_vs_main(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    return mesh_vertex(d.position, d.normal);
}

@vertex fn deformed_vs_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    var output = mesh_vertex(d.position, d.normal);
    output.color = color;
    return output;
}

@vertex fn deformed_vs_textured(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    return textured_vertex(d.position, d.normal, uv0, uv1);
}

@vertex fn deformed_vs_standard_tangent(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, tangent);
    var output = textured_vertex(d.position, d.normal, uv0, uv1);
    output.tangent = vec4((uniforms.model * vec4(d.tangent.xyz, 0.)).xyz, d.tangent.w * uniforms.pbr_factors.z);
    return output;
}

@vertex fn deformed_vs_textured_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    var output = textured_vertex(d.position, d.normal, uv0, uv1);
    output.color = color;
    return output;
}

@vertex fn deformed_vs_standard_tangent_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>,
    @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, tangent);
    var output = textured_vertex(d.position, d.normal, uv0, uv1);
    output.color = color;
    output.tangent = vec4((uniforms.model * vec4(d.tangent.xyz, 0.)).xyz, d.tangent.w * uniforms.pbr_factors.z);
    return output;
}

@vertex fn deformed_vs_instance_main(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    var output = instance_vertex(d.position, d.normal, instance);
    return output;
}

@vertex fn deformed_vs_instance_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(5) color: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    var output = instance_vertex(d.position, d.normal, instance);
    output.color *= color;
    return output;
}

@vertex fn deformed_vs_instance_textured(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    var output = instance_vertex(d.position, d.normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    return output;
}

@vertex fn deformed_vs_instance_textured_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, vec4(1.,0.,0.,1.));
    var output = instance_vertex(d.position, d.normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    output.color *= color;
    return output;
}

@vertex fn deformed_vs_instance_standard_tangent(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, tangent);
    var output = instance_vertex(d.position, d.normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    output.tangent = vec4((uniforms.model * instance_matrix(instance) * vec4(d.tangent.xyz, 0.)).xyz, d.tangent.w * uniforms.pbr_factors.z * instance.normal0.w);
    return output;
}

@vertex fn deformed_vs_instance_standard_tangent_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, instance: InstanceInput, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(4) tangent: vec4<f32>, @location(5) color: vec4<f32>) -> VertexOutput {
    let d = deform_vertex(index, position, normal, tangent);
    var output = instance_vertex(d.position, d.normal, instance);
    output.uv = select(uv0, uv1, uniforms.map_params.x > 0.5);
    output.uv0 = uv0; output.uv1 = uv1;
    output.tangent = vec4((uniforms.model * instance_matrix(instance) * vec4(d.tangent.xyz, 0.)).xyz, d.tangent.w * uniforms.pbr_factors.z * instance.normal0.w);
    output.color *= color;
    return output;
}
