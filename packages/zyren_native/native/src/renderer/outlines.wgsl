struct Style { color: vec4<f32>, params: vec4<f32> };
@group(0) @binding(0) var coverage: texture_2d<f32>;
@group(0) @binding(1) var<uniform> style: Style;
@group(0) @binding(2) var background: texture_2d<f32>;
fn to_srgb(c: vec3<f32>) -> vec3<f32> {
 return select(1.055 * pow(max(c, vec3(0.)), vec3(1./2.4)) - .055, c * 12.92, c <= vec3(.0031308));
}
fn from_srgb(c: vec3<f32>) -> vec3<f32> {
 return select(pow(max((c+.055)/1.055, vec3(0.)), vec3(2.4)), c/12.92, c <= vec3(.04045));
}

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
    if center <= 0. && style.params.z < .5 { discard; }
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
    if opacity <= 0. && style.params.z < .5 { discard; }
    if style.params.z > .5 {
        let base = textureLoad(background, point, 0);
        var rgb = base.rgb;
        if style.params.w > .5 {
            let encoded = select(rgb, to_srgb(rgb), style.params.y > .5);
            rgb = from_srgb(encoded / max(base.a, 1e-8));
        } else if style.params.y < .5 {
            rgb = from_srgb(rgb);
        }
        let a = opacity + base.a * (1. - opacity);
        rgb = (style.color.rgb * opacity + rgb * base.a * (1. - opacity)) / max(a, 1e-8);
        if style.params.w > .5 {
            let encoded = to_srgb(rgb) * a;
            rgb = select(encoded, from_srgb(encoded), style.params.y > .5);
        } else if style.params.y < .5 {
            rgb = to_srgb(rgb);
        }
        return vec4(rgb, a);
    }
    return vec4(select(to_srgb(style.color.rgb), style.color.rgb, style.params.y > .5), opacity);
}
