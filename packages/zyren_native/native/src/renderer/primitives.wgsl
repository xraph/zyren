struct PrimitiveOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) corner: vec2<f32>,
    @location(1) @interpolate(flat) circle: u32,
    @location(2) color: vec4<f32>,
    @location(3) relative_position: vec3<f32>,
};
struct ClippedSegment {
    a: vec4<f32>,
    b: vec4<f32>,
    visible: bool,
    first: f32,
    last: f32,
};
fn clip_segment(a: vec4<f32>, b: vec4<f32>) -> ClippedSegment {
    var first = 0.0;
    var last = 1.0;
    let starts = vec3<f32>(a.z, a.w - a.z, a.w - 0.000001);
    let ends = vec3<f32>(b.z, b.w - b.z, b.w - 0.000001);
    for (var plane = 0u; plane < 3u; plane++) {
        let start = starts[plane];
        let end = ends[plane];
        if start < 0.0 && end < 0.0 { return ClippedSegment(a, b, false, 0., 1.); }
        if start < 0.0 { first = max(first, start / (start - end)); }
        if end < 0.0 { last = min(last, start / (start - end)); }
    }
    return ClippedSegment(mix(a, b, first), mix(a, b, last), first <= last, first, last);
}
fn quad_corner(vertex: u32) -> vec2<f32> {
    switch vertex % 4u {
        case 0u: { return vec2<f32>(-1.0, -1.0); }
        case 1u: { return vec2<f32>(1.0, -1.0); }
        case 2u: { return vec2<f32>(1.0, 1.0); }
        default: { return vec2<f32>(-1.0, 1.0); }
    }
}
fn camera_right() -> vec3<f32> {
    let vp = uniforms.view_projection;
    return normalize(vec3<f32>(vp[0].x, vp[1].x, vp[2].x));
}
fn camera_up() -> vec3<f32> {
    let vp = uniforms.view_projection;
    return normalize(vec3<f32>(vp[0].y, vp[1].y, vp[2].y));
}
fn hidden_primitive() -> PrimitiveOutput {
    return PrimitiveOutput(vec4<f32>(0.0, 0.0, -1.0, 1.0), vec2<f32>(0.0), 0u, vec4(1.), vec3(0.));
}
fn line_vertex(start: vec3<f32>, end: vec3<f32>, vertex: u32, first_color: vec4<f32>, last_color: vec4<f32>) -> PrimitiveOutput {
    let clipped = clip_segment(uniforms.mvp * vec4<f32>(start, 1.0), uniforms.mvp * vec4<f32>(end, 1.0));
    if !clipped.visible { return hidden_primitive(); }
    let delta = (clipped.b.xy / clipped.b.w - clipped.a.xy / clipped.a.w) * uniforms.viewport.xy;
    if dot(delta, delta) < 0.00000001 { return hidden_primitive(); }
    let corner = quad_corner(vertex);
    var position = select(clipped.a, clipped.b, corner.x > 0.0);
    if uniforms.primitive.y < 0.5 {
        let perpendicular = normalize(vec2<f32>(-delta.y, delta.x));
        position = vec4<f32>(position.xy + perpendicular * corner.y * uniforms.primitive.x / uniforms.viewport.xy * position.w, position.zw);
    } else {
        let direction = (uniforms.model * vec4<f32>(end - start, 0.0)).xyz;
        let right = camera_right();
        let up = camera_up();
        let tangent = vec2<f32>(dot(direction, right), dot(direction, up));
        if dot(tangent, tangent) < 0.00000001 { return hidden_primitive(); }
        let perpendicular = normalize(vec2<f32>(-tangent.y, tangent.x));
        let offset = (right * perpendicular.x + up * perpendicular.y) * corner.y * uniforms.primitive.x * 0.5;
        position += uniforms.view_projection * vec4<f32>(offset, 0.0);
    }
    return PrimitiveOutput(position, corner, 0u, mix(first_color, last_color, select(clipped.first, clipped.last, corner.x > 0.)), (uniforms.model * vec4(mix(start,end,select(clipped.first,clipped.last,corner.x>0.)),1.)).xyz);
}
fn point_vertex(center: vec3<f32>, vertex: u32, color: vec4<f32>) -> PrimitiveOutput {
    var position = uniforms.mvp * vec4<f32>(center, 1.0);
    if position.z > position.w || position.z < 0.0 || position.w < 0.000001 { return hidden_primitive(); }
    let corner = quad_corner(vertex);
    if uniforms.primitive.y < 0.5 {
        position = vec4<f32>(position.xy + corner * uniforms.primitive.x / uniforms.viewport.xy * position.w, position.zw);
    } else {
        let offset = (camera_right() * corner.x + camera_up() * corner.y) * uniforms.primitive.x * 0.5;
        position += uniforms.view_projection * vec4<f32>(offset, 0.0);
    }
    return PrimitiveOutput(position, corner, u32(uniforms.primitive.z), color, (uniforms.model * vec4(center,1.)).xyz);
}
@fragment fn fs_primitive(input: PrimitiveOutput) -> @location(0) vec4<f32> {
    let ndc=vec4(input.position.x/uniforms.viewport.x*2.-1., 1.-input.position.y/uniforms.viewport.y*2., input.position.z, 1.);
    let world=uniforms.inverse_view_projection*ndc;
    clip_fragment(world.xyz/world.w, input.position.xy);
    if input.circle == 1u && dot(input.corner, input.corner) > 1.0 { discard; }
    return shade(vec3<f32>(0.0, 0.0, 1.0), input.color);
}

@vertex fn vs_line(@location(0) start: vec3<f32>, @location(1) end: vec3<f32>, @builtin(vertex_index) vertex: u32) -> PrimitiveOutput {
    return line_vertex(start, end, vertex, vec4(1.), vec4(1.));
}
@vertex fn vs_line_colored(@location(0) start: vec3<f32>, @location(1) end: vec3<f32>, @location(5) a: vec4<f32>, @location(6) b: vec4<f32>, @builtin(vertex_index) vertex: u32) -> PrimitiveOutput {
    return line_vertex(start, end, vertex, a, b);
}
@vertex fn vs_point(@location(0) center: vec3<f32>, @builtin(vertex_index) vertex: u32) -> PrimitiveOutput {
    return point_vertex(center, vertex, vec4(1.));
}
@vertex fn vs_point_colored(@location(0) center: vec3<f32>, @location(5) color: vec4<f32>, @builtin(vertex_index) vertex: u32) -> PrimitiveOutput {
    return point_vertex(center, vertex, color);
}
