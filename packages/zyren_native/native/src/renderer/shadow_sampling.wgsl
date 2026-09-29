struct ShadowView {
    projection: mat4x4<f32>, rect: vec4<f32>, params: vec4<f32>, interval: vec4<f32>,
};
struct Shadows {
    forward: vec4<f32>, lights: array<vec4<u32>,20>, views: array<ShadowView,128>,
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

fn cube_shadow_face(offset:vec3<f32>) -> u32 {
    let magnitude=abs(offset);
    if(magnitude.x>=magnitude.y && magnitude.x>=magnitude.z) {return select(1u,0u,offset.x>=0.);}
    if(magnitude.y>=magnitude.z) {return select(3u,2u,offset.y>=0.);}
    return select(5u,4u,offset.z>=0.);
}
fn shadowed_area(index:u32,position:vec3<f32>,geometric_normal:vec3<f32>,n:vec3<f32>,v:vec3<f32>,tangent:vec4<f32>,surface:StandardSurface) -> vec3<f32> {
    let light=lighting.areas[index];
    let views=shadows.lights[16u+index];
    if(uniforms.pbr_params.z<.5 || views.y==0u) {return shade_area(light,position,n,v,tangent,surface);}
    var result=vec3(0.);
    for(var quadrant=0u;quadrant<4u;quadrant++) {
        var part=light;
        let offset=light.half_width.xyz*(f32(quadrant%2u)-.5)+light.half_height.xyz*(f32(quadrant/2u)-.5);
        part.position=vec4(light.position.xyz+offset,0.);
        part.half_width*=.5;
        part.half_height*=.5;
        let toward=part.position.xyz-position;
        let face=cube_shadow_face(-toward);
        let visibility=sample_shadow(views.x+quadrant*6u+face,position,geometric_normal,normalized_or(toward,geometric_normal));
        result+=shade_area(part,position,n,v,tangent,surface)*visibility;
    }
    return result;
}
