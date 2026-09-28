struct ShadowView {
    projection: mat4x4<f32>, rect: vec4<f32>, params: vec4<f32>, interval: vec4<f32>,
};
struct Shadows {
    forward: vec4<f32>, lights: array<vec4<u32>,16>, views: array<ShadowView,32>,
};
@group(0) @binding(8) var<uniform> shadows: Shadows;
@group(0) @binding(9) var shadow_atlas: texture_depth_2d;
@group(0) @binding(10) var shadow_sampler: sampler_comparison;
fn sample_shadow(index: u32, position: vec3<f32>, normal: vec3<f32>, l: vec3<f32>) -> f32 {
    let view = shadows.views[index];
    let clip = view.projection * vec4(position + normal * view.params.y, 1.);
    if (clip.w <= 0.) { return 1.; }
    let ndc = clip.xyz / clip.w;
    if (any(abs(ndc.xy) > vec2(1.)) || ndc.z < 0. || ndc.z > 1.) { return 1.; }
    let uv = view.rect.xy + (ndc.xy * vec2(.5,-.5) + vec2(.5)) * view.rect.z;
    let reference = ndc.z - view.params.x - view.params.z * (1. - max(dot(normal,l),0.));
    let texel = 1. / f32(textureDimensions(shadow_atlas).x);
    let minimum = view.rect.xy + vec2(.5 * texel);
    let maximum = view.rect.xy + vec2(view.rect.z - .5 * texel);
    var visibility = 0.;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let tap = clamp(uv + vec2(f32(x),f32(y)) * texel * view.params.w, minimum, maximum);
            visibility += textureSampleCompareLevel(shadow_atlas, shadow_sampler, tap, reference);
        }
    }
    return mix(1., visibility / 9., view.interval.w);
}
fn shadow_visibility(light_index: u32, position: vec3<f32>, normal: vec3<f32>, l: vec3<f32>) -> f32 {
    let light_views = shadows.lights[light_index];
    if (uniforms.pbr_params.z < .5 || light_views.y == 0u) { return 1.; }
    var face = 0u;
    if (light_views.z == 1u) {
        let offset = position - lighting.lights[light_index].position_kind.xyz;
        let magnitude = abs(offset);
        if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) { face = select(1u,0u,offset.x >= 0.); }
        else if (magnitude.y >= magnitude.z) { face = select(3u,2u,offset.y >= 0.); }
        else { face = select(5u,4u,offset.z >= 0.); }
    } else if (light_views.z == 0u) {
        let camera_depth = dot(position, shadows.forward.xyz);
        while (face < light_views.y && camera_depth > shadows.views[light_views.x + face].interval.y) { face++; }
        if (face == light_views.y) { return 1.; }
        let index = light_views.x + face;
        let interval = shadows.views[index].interval;
        let current = sample_shadow(index, position, normal, l);
        let width = (interval.y - interval.x) * interval.z;
        if (face + 1u < light_views.y && width > 0. && camera_depth > interval.y - width) {
            return mix(current, sample_shadow(index + 1u, position, normal, l), clamp((camera_depth - interval.y + width) / width, 0., 1.));
        }
        return current;
    }
    return sample_shadow(light_views.x + face, position, normal, l);
}
