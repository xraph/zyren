struct Style { color: vec4<f32>, params: vec4<f32> };
@group(0) @binding(0) var coverage: texture_2d<f32>;
@group(0) @binding(1) var<uniform> style: Style;

@vertex fn vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
    let uv = vec2<f32>(f32((index << 1u) & 2u), f32(index & 2u));
    return vec4<f32>(uv * 2. - 1., 0., 1.);
}
fn alpha(point: vec2<i32>, size: vec2<i32>) -> f32 {
    if any(point < vec2<i32>(0)) || any(point >= size) { return 0.; }
    return textureLoad(coverage, point, 0).a;
}
@fragment fn fragment(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    let point = vec2<i32>(position.xy);
    let size = vec2<i32>(textureDimensions(coverage));
    let center = alpha(point, size);
    if center <= 0. { discard; }
    let radius = i32(style.params.x);
    var minimum = center;
    for (var y = -radius; y <= radius; y++) {
        for (var x = -radius; x <= radius; x++) {
            if x*x + y*y <= radius*radius {
                minimum = min(minimum, alpha(point + vec2<i32>(x,y), size));
            }
        }
    }
    let opacity = (center - minimum) * style.color.a;
    if opacity <= 0. { discard; }
    var color = style.color.rgb;
    if style.params.y < .5 {
        color = select(1.055 * pow(color, vec3<f32>(1./2.4)) - .055,
            color * 12.92, color <= vec3<f32>(.0031308));
    }
    return vec4<f32>(color, opacity);
}
