@group(0) @binding(0) var source: texture_2d<f32>;

@vertex fn vertex(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
    let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
    return vec4(positions[index], 0., 1.);
}

fn reduce(position: vec2<f32>, weighted: bool) -> vec4<f32> {
    let size = textureDimensions(source);
    let destination_size = max(size / 2u, vec2<u32>(1u));
    let ratio = vec2<f32>(size) / vec2<f32>(destination_size);
    let lo = floor(position) * ratio;
    let hi = (floor(position) + vec2(1.)) * ratio;
    var sum = vec4(0.);
    var area = 0.;
    for (var y = i32(floor(lo.y)); y < i32(ceil(hi.y)); y++) {
        for (var x = i32(floor(lo.x)); x < i32(ceil(hi.x)); x++) {
            let cell = vec2<f32>(f32(x), f32(y));
            let overlap = max(min(hi, cell + vec2(1.)) - max(lo, cell), vec2(0.));
            let weight = overlap.x * overlap.y;
            var color = textureLoad(source, vec2(x, y), 0);
            if weighted { color = vec4(color.rgb * color.a, color.a); }
            sum += color * weight;
            area += weight;
        }
    }
    if weighted {
        if sum.a > 0. { return vec4(sum.rgb / sum.a, sum.a / area); }
        return vec4(0.);
    }
    return sum / area;
}

@fragment fn independent(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    return reduce(position.xy, false);
}
@fragment fn weighted(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    return reduce(position.xy, true);
}
