struct PunctualLight {
    position_kind: vec4<f32>,
    direction_range: vec4<f32>,
    color_intensity: vec4<f32>,
    cone: vec4<f32>,
};
struct Lighting {
    count: vec4<u32>,
    lights: array<PunctualLight, 16>,
};
@group(0) @binding(1) var<uniform> lighting: Lighting;

fn normalized_or(v: vec3<f32>, fallback: vec3<f32>) -> vec3<f32> {
    let length_squared = dot(v, v);
    return select(fallback, v * inverseSqrt(max(length_squared, 1e-20)), length_squared > 1e-20);
}

fn direct_brdf(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, base: vec3<f32>) -> vec3<f32> {
    let nl = max(dot(n, l), 0.);
    let nv = max(dot(n, v), 0.);
    if (nl <= 0. || nv <= 0.) { return vec3(0.); }
    let h = normalized_or(l + v, n);
    let nh = max(dot(n, h), 0.);
    let vh = clamp(dot(v, h), 0., 1.);
    let metallic = uniforms.pbr_params.x;
    let alpha = max(uniforms.pbr_params.y * uniforms.pbr_params.y, 0.002025);
    let a2 = alpha * alpha;
    let denominator = nh * nh * (a2 - 1.) + 1.;
    let distribution = a2 / (3.141592653589793 * denominator * denominator);
    let visibility = 0.5 / max(nl * sqrt(a2 + (1. - a2) * nv * nv)
        + nv * sqrt(a2 + (1. - a2) * nl * nl), 1e-12);
    let f0 = mix(vec3(0.04), base, metallic);
    let fresnel = f0 + (vec3(1.) - f0) * pow(1. - vh, 5.);
    let diffuse = (vec3(1.) - fresnel) * (1. - metallic) * base / 3.141592653589793;
    return (diffuse + fresnel * distribution * visibility) * nl;
}

fn shade_standard(input: VertexOutput, front: bool, texel: vec4<f32>) -> vec4<f32> {
    let alpha = texel.a * uniforms.map_params.y;
    let mode = uniforms.map_params.w;
    if (mode > 0.5 && mode < 1.5 && alpha < uniforms.map_params.z) { discard; }
    let n = normalized_or(select(-input.normal, input.normal, front), vec3(0., 0., 1.));
    let v = normalized_or(-input.relative_position, n);
    let base = texel.rgb * uniforms.color_unlit.rgb;
    var color = uniforms.emissive.rgb;
    for (var i = 0u; i < lighting.count.x; i++) {
        let light = lighting.lights[i];
        var l = -light.direction_range.xyz;
        var attenuation = 1.;
        if (light.position_kind.w > 0.5) {
            let offset = light.position_kind.xyz - input.relative_position;
            let distance_squared = dot(offset, offset);
            l = normalized_or(offset, n);
            attenuation = 1. / max(distance_squared, 1e-6);
            if (light.direction_range.w > 0.) {
                let ratio_squared = distance_squared / (light.direction_range.w * light.direction_range.w);
                attenuation *= max(1. - ratio_squared * ratio_squared, 0.);
            }
            if (light.position_kind.w > 1.5) {
                let cosine = dot(-l, light.direction_range.xyz);
                let width = light.cone.x - light.cone.y;
                var cone = select(0., 1., cosine >= light.cone.x);
                if (width > 0.) {
                    cone = clamp((cosine - light.cone.y) / width, 0., 1.);
                }
                attenuation *= cone * cone;
            }
        }
        color += direct_brdf(n, v, l, base) * light.color_intensity.rgb * light.color_intensity.w * attenuation;
    }
    return vec4(color, select(1., alpha, mode > 1.5));
}
@fragment fn fs_standard(input: VertexOutput, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    return shade_standard(input, front, vec4(1.));
}
@fragment fn fs_standard_textured(input: VertexOutput, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    return shade_standard(input, front, textureSample(color_map, color_sampler, input.uv));
}
