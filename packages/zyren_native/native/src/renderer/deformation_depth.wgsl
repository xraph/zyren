@vertex fn deformed_vs_depth(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.orientation = 1.;
    output.alpha = 1.;
    output.position = depth.mvp * vec4(d.position, 1.);
    output.relative_position = (depth.model * vec4(d.position, 1.)).xyz;
    output.uv = vec2(0.);
    return output;
}

@vertex fn deformed_vs_depth_textured(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.orientation = 1.;
    output.alpha = 1.;
    output.position = depth.mvp * vec4(d.position, 1.);
    output.relative_position = (depth.model * vec4(d.position, 1.)).xyz;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    return output;
}

@vertex fn deformed_vs_depth_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(5) color: vec4<f32>) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.orientation = 1.;
    output.position = depth.mvp * vec4(d.position, 1.);
    output.relative_position = (depth.model * vec4(d.position, 1.)).xyz;
    output.alpha = color.a;
    return output;
}

@vertex fn deformed_vs_depth_textured_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.orientation = 1.;
    output.position = depth.mvp * vec4(d.position, 1.);
    output.relative_position = (depth.model * vec4(d.position, 1.)).xyz;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    output.alpha = color.a;
    return output;
}

@vertex fn deformed_vs_instance_depth(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, instance: DepthInstance) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = 1.;
    return output;
}

@vertex fn deformed_vs_instance_depth_textured(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, instance: DepthInstance, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = 1.;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    return output;
}

@vertex fn deformed_vs_instance_depth_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, instance: DepthInstance, @location(5) color: vec4<f32>) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = color.a;
    return output;
}

@vertex fn deformed_vs_instance_depth_textured_colored(@builtin(vertex_index) index: u32, @location(0) position: vec3<f32>, instance: DepthInstance, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>, @location(5) color: vec4<f32>) -> DepthOutput {
    let d = deform_vertex(index, position, vec3(0.,0.,1.), vec4(1.,0.,0.,1.));
    var output: DepthOutput;
    output.position = depth.mvp * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.);
    output.relative_position = (depth.model * mat4x4(instance.model0, instance.model1, instance.model2, instance.model3) * vec4(d.position, 1.)).xyz;
    output.orientation = instance.normal0.w;
    output.alpha = color.a;
    output.uv = select(uv0, uv1, depth.params.w > .5);
    return output;
}
