@group(0) @binding(15) var volume_environment: texture_3d<f32>;
struct EnvironmentSettings { params: vec4<f32>, rotation: vec4<f32> };
@group(0) @binding(2) var<uniform> environment: EnvironmentSettings;
@group(0) @binding(3) var diffuse_environment: texture_2d<f32>;
@group(0) @binding(4) var specular_environment: texture_2d<f32>;
@group(0) @binding(5) var environment_brdf: texture_2d<f32>;
@group(0) @binding(6) var environment_sampler: sampler;
@group(0) @binding(7) var brdf_sampler: sampler;
fn environment_uv(direction: vec3<f32>) -> vec2<f32> {
    let q = vec4(-environment.rotation.xyz, environment.rotation.w);
    let local = direction + 2. * cross(q.xyz, cross(q.xyz, direction) + q.w * direction);
    return vec2(atan2(local.z, local.x) / (2. * 3.141592653589793) + .5, acos(clamp(local.y, -1., 1.)) / 3.141592653589793);
}
fn environment_specular(direction: vec3<f32>, roughness: f32) -> vec3<f32> {
    let uv = environment_uv(direction);
    if environment.params.z > .5 {
        let layers = environment.params.y + 1.;
        return textureSampleLevel(volume_environment, environment_sampler, vec3(uv, (roughness * environment.params.y + .5) / layers), 0.).rgb;
    }
    return textureSampleLevel(specular_environment, environment_sampler, uv, roughness * environment.params.y).rgb;
}
// A/B match the correlated-Smith GGX integral, including the roughness floor.
fn energy_brdf(nv: f32, roughness: f32) -> vec2<f32> {
    let extent = vec2<f32>(textureDimensions(environment_brdf));
    let uv = (vec2(clamp(nv,0.,1.),roughness) * (extent-vec2(1.)) + vec2(.5)) / extent;
    return textureSampleLevel(environment_brdf, brdf_sampler, uv, 0.).rg;
}
fn energy_scale(f0: vec3<f32>, brdf: vec2<f32>) -> vec3<f32> {
    let white = clamp(brdf.x + brdf.y, 1e-4, 1.);
    return vec3(1.) + f0 * (1. / white - 1.);
}
fn diffuse_budget(f0: vec3<f32>, f90: f32, brdf: vec2<f32>) -> f32 {
    return clamp(1. - maximum3((f0 * brdf.x + vec3(f90 * brdf.y)) * energy_scale(f0,brdf)),0.,1.);
}
fn standard_energy(nv: f32, surface: StandardSurface) -> vec4<f32> {
    let brdf = energy_brdf(nv,surface.roughness);
    let f0 = mix(vec3(.04), surface.base.rgb, surface.metallic);
    return vec4(energy_scale(f0,brdf),diffuse_budget(vec3(.04),1.,brdf));
}
fn specular_occlusion(nv: f32, roughness: f32, ao: f32) -> f32 {
    return clamp(pow(nv+ao,exp2(-16.*roughness-1.))-1.+ao,0.,1.);
}
fn filtered_roughness(roughness: f32, normal_variance: f32) -> f32 {
    // Zero preserves the exact original value, including perfect mirrors.
    if (uniforms.pbr_params.w == 0. || uniforms.emissive.w == 0.) { return roughness; }
    let alpha = roughness*roughness;
    return sqrt(sqrt(min(1.,alpha*alpha+min(uniforms.pbr_params.w*normal_variance,uniforms.emissive.w))));
}
fn shade_environment(n: vec3<f32>, v: vec3<f32>, surface: StandardSurface) -> vec3<f32> {
    if (environment.params.x == 0. && surface.screen_reflection.a == 0.) {return vec3(0.);}
    let nv = clamp(dot(n,v), 0., 1.);
    let f0 = mix(vec3(.04), surface.base.rgb, surface.metallic);
    let energy = standard_energy(nv,surface);
    let diffuse = textureSampleLevel(diffuse_environment, environment_sampler, environment_uv(n), 0.).rgb / select(1.,3.141592653589793,environment.params.z>.5);
    let specular = mix(environment_specular(reflect(-v,n), surface.roughness) * environment.params.x, surface.screen_reflection.rgb, surface.screen_reflection.a);
    let brdf = energy_brdf(nv,surface.roughness);
    return (energy.w * (1. - surface.metallic) * surface.base.rgb * diffuse * surface.occlusion * environment.params.x
        + specular * (f0 * brdf.x + brdf.y) * energy.rgb * specular_occlusion(nv,surface.roughness,surface.occlusion));
}

struct PunctualLight {
    position_kind: vec4<f32>,
    direction_range: vec4<f32>,
    color_intensity: vec4<f32>,
    cone: vec4<f32>,
};
struct HemisphereLight { sky_intensity: vec4<f32>, ground: vec4<f32>, direction: vec4<f32> };
struct AreaLight { position: vec4<f32>, half_width: vec4<f32>, half_height: vec4<f32>, color_intensity: vec4<f32> };
struct Lighting {
    count: vec4<u32>,
    lights: array<PunctualLight, 16>,
    hemispheres: array<HemisphereLight, 4>,
    areas: array<AreaLight, 4>,
};
@group(0) @binding(1) var<uniform> lighting: Lighting;

fn normalized_or(v: vec3<f32>, fallback: vec3<f32>) -> vec3<f32> {
    let length_squared = dot(v, v);
    return select(fallback, v * inverseSqrt(max(length_squared, 1e-20)), length_squared > 1e-20);
}

fn direct_brdf(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, base: vec3<f32>, metallic: f32, roughness: f32, energy: vec4<f32>) -> vec3<f32> {
    let nl = clamp(dot(n, l), 0., 1.);
    let nv = clamp(dot(n, v), 0., 1.);
    if (nl <= 0. || nv <= 0.) { return vec3(0.); }
    let h = normalized_or(l + v, n);
    let nh = clamp(dot(n, h), 0., 1.);
    let vh = clamp(dot(v, h), 0., 1.);
    let alpha = max(roughness * roughness, 0.002025);
    let a2 = alpha * alpha;
    // |N x H|^2 avoids cancellation in 1 - (N.H)^2 at glossy peaks.
    let cross_nh = cross(n, h);
    let denominator = dot(cross_nh, cross_nh) + a2 * nh * nh;
    let distribution = a2 / (3.141592653589793 * denominator * denominator);
    let visibility = 0.5 / max(nl * sqrt(a2 + (1. - a2) * nv * nv)
        + nv * sqrt(a2 + (1. - a2) * nl * nl), 1e-12);
    let f0 = mix(vec3(0.04), base, metallic);
    let fresnel = f0 + (vec3(1.) - f0) * pow(1. - vh, 5.);
    let diffuse = energy.w * (1. - metallic) * base / 3.141592653589793;
    return (diffuse + fresnel * distribution * visibility * energy.rgb) * nl;
}

fn shade_standard(input: VertexOutput, front: bool, original: StandardSurface) -> vec4<f32> {
    // Evaluate derivatives in uniform control flow before clipping or alpha discard.
    let dx = dpdx(original.normal);
    let dy = dpdy(original.normal);
    let coat_dx = dpdx(original.coat_normal);
    let coat_dy = dpdy(original.coat_normal);
    let source_scale=vec2<f32>(textureDimensions(screen_depth))/uniforms.viewport.xy;
    let pixel_size=max(length(dpdx(input.relative_position))/source_scale.x,length(dpdy(input.relative_position))/source_scale.y);
    var surface=original;
    surface.roughness=filtered_roughness(surface.roughness,dot(dx,dx)+dot(dy,dy));
    if (COAT) { surface.physical[0].w=filtered_roughness(surface.physical[0].w,dot(coat_dx,coat_dx)+dot(coat_dy,coat_dy)); }
    clip_fragment(input.relative_position, input.position.xy);
    surface.coat_normal=select(-surface.coat_normal,surface.coat_normal,front);
    if (surface.transmission[0].y>0. && surface.transmission[0].x>0. && surface.metallic<1. && !front) {discard;}
    let alpha = surface.base.a * uniforms.map_params.y;
    let mode = uniforms.map_params.w;
    if (mode > 0.5 && mode < 1.5 && alpha < uniforms.map_params.z) { discard; }
    let n = select(-surface.normal, surface.normal, front);
    let v = normalized_or(-input.relative_position, n);
    if (mode<1.5 && !TRANSMISSION && surface.transmission[0].x==0.) {
        surface.occlusion*=screen_ao(input.position.xy*source_scale,input.relative_position,n,pixel_size);
        if (!COAT && !SHEEN && !ANISOTROPY && !IRIDESCENCE) {
            surface.screen_reflection=screen_reflection(input.relative_position,n,v,surface.roughness);
        }
    }
    let base = surface.base.rgb;
    let physical = PHYSICAL;
    var physical_view: PhysicalView;
    if (physical) { physical_view = prepare_physical(n, v, input.tangent, surface); }
    let energy = standard_energy(clamp(dot(n,v),0.,1.),surface);
    let coat = select(0., physical_view.coat_fresnel, physical && COAT);
    var color = surface.emission * (1.-coat) + physical_environment(n, v, input.tangent, surface, physical_view);
    for (var i = 0u; i < lighting.count.y; i++) {
        let light = lighting.hemispheres[i];
        let weight = clamp(dot(n, light.direction.xyz) * 0.5 + 0.5, 0., 1.);
        let irradiance = mix(light.ground.rgb, light.sky_intensity.rgb, weight) * light.sky_intensity.w;
        let diffuse_weight = select(energy.w, physical_view.diffuse_weight, physical);
        color += irradiance * base * (1. - surface.metallic) * (1.-surface.transmission[0].x) * (diffuse_weight / 3.141592653589793) * surface.occlusion * (1.-coat);
    }
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
        var response: vec3<f32>;
        if (physical) {
            response = physical_direct_prepared(n, v, l, surface, physical_view);
        } else {
            response = direct_brdf(n, v, l, base, surface.metallic, surface.roughness, energy);
        }
        color += response * light.color_intensity.rgb * light.color_intensity.w * attenuation
            * shadow_visibility(i, input.relative_position, select(-normalized_or(input.normal,n), normalized_or(input.normal,n), front), l);
    }
    for (var i = 0u; i < lighting.count.z; i++) {
        color += shadowed_area(i, input.relative_position, select(-normalized_or(input.normal,n), normalized_or(input.normal,n), front), n, v, input.tangent, surface);
    }
    let transmission=physical_transmission(input,n,v,surface);
    color+=transmission.rgb;
    let coverage=transmission.a;
    return vec4(select(color,color/max(coverage,1e-8),mode>1.5),coverage*select(1.,alpha,mode>1.5));
}

struct StandardSurface {
    base: vec4<f32>, normal: vec3<f32>, metallic: f32, roughness: f32,
    emission: vec3<f32>, occlusion: f32,
    physical: array<vec4<f32>,4>, coat_normal: vec3<f32>,
    transmission: array<vec4<f32>,2>,
    optical: array<vec4<f32>,2>,
    screen_reflection: vec4<f32>,
};
fn standard_surface(input: VertexOutput) -> StandardSurface {
    var surface: StandardSurface;
    surface.base = vec4(uniforms.color_unlit.rgb, 1.) * input.color;
    surface.normal = normalized_or(input.normal, vec3(0.,0.,1.));
    surface.metallic = uniforms.pbr_params.x;
    surface.roughness = uniforms.pbr_params.y;
    surface.emission = uniforms.emissive.rgb;
    surface.occlusion = 1.;
    surface.physical = uniforms.physical;
    surface.transmission = uniforms.transmission;
    surface.optical = uniforms.optical;
    surface.coat_normal = surface.normal;
    return surface;
}
@group(1) @binding(2) var normal_map: texture_2d<f32>;
@group(1) @binding(3) var normal_sampler: sampler;
@group(1) @binding(4) var metallic_roughness_map: texture_2d<f32>;
@group(1) @binding(5) var metallic_roughness_sampler: sampler;
@group(1) @binding(6) var occlusion_map: texture_2d<f32>;
@group(1) @binding(7) var occlusion_sampler: sampler;
@group(1) @binding(8) var emissive_map: texture_2d<f32>;
@group(1) @binding(9) var emissive_sampler: sampler;
fn material_uv(input: VertexOutput, slot: u32) -> vec2<f32> {
    return select(input.uv0, input.uv1, (uniforms.pbr_maps.y & (1u << slot)) != 0u);
}
fn mapped_normal(input: VertexOutput, uv: vec2<f32>, sample: vec3<f32>, scale: vec2<f32>) -> vec3<f32> {
    let n = normalized_or(input.normal, vec3(0.,0.,1.));
    // Evaluate derivatives before branching on interpolated tangent data.
    let dx = dpdx(input.relative_position); let dy = dpdy(input.relative_position);
    let ux = dpdx(uv); let uy = dpdy(uv);
    let determinant = ux.x * uy.y - ux.y * uy.x;
    let orientation = select(-1., 1., determinant >= 0.);
    var raw_t = (dx * uy.y - dy * ux.y) * orientation;
    let raw_b = (dy * ux.x - dx * uy.x) * orientation;
    let explicit_t = input.tangent.xyz - n * dot(n, input.tangent.xyz);
    let has_tangent = abs(input.tangent.w) > 0.5 && dot(explicit_t, explicit_t) > 1e-20;
    if (has_tangent) { raw_t = explicit_t; }
    if ((!has_tangent && abs(determinant) < 1e-20) || dot(raw_t,raw_t) < 1e-20) { return n; }
    let t = normalized_or(raw_t - n * dot(n, raw_t), vec3(1.,0.,0.));
    var handedness = select(-1., 1., dot(cross(n,t), raw_b) >= 0.);
    if (has_tangent) { handedness = input.tangent.w; }
    let b = cross(n,t) * handedness;
    let encoded = sample * 2. - vec3(1.);
    let local = encoded * vec3(scale,1.);
    return normalized_or(t * local.x + b * local.y + n * local.z, n);
}
@fragment fn fs_standard(input: VertexOutput, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    return shade_standard(input, material_front(front, input.orientation), physical_surface(input,standard_surface(input)));
}
@fragment fn fs_standard_textured(input: VertexOutput, @builtin(front_facing) front: bool) -> @location(0) vec4<f32> {
    var surface = standard_surface(input);
    let flags = uniforms.pbr_maps.x;
    if ((flags & 1u) != 0u) {
        surface.base *= textureSample(color_map, color_sampler, material_uv(input,0u));
    }
    if ((flags & 2u) != 0u) {
        let uv = material_uv(input,1u);
        surface.normal = mapped_normal(input, uv, textureSample(normal_map, normal_sampler, uv).rgb,uniforms.pbr_factors.xw);
    }
    if ((flags & 4u) != 0u) {
        let sample = textureSample(metallic_roughness_map, metallic_roughness_sampler, material_uv(input,2u));
        surface.metallic *= sample.b;
        surface.roughness *= sample.g;
    }
    if ((flags & 8u) != 0u) {
        let occlusion = textureSample(occlusion_map, occlusion_sampler, material_uv(input,3u)).r;
        surface.occlusion = mix(1., occlusion, uniforms.pbr_factors.y);
    }
    if ((flags & 16u) != 0u) {
        surface.emission *= textureSample(emissive_map, emissive_sampler, material_uv(input,4u)).rgb;
    }
    return shade_standard(input, material_front(front, input.orientation), physical_surface(input,surface));
}
