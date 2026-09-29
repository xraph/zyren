// Layered reflectance. See docs/design/physical-materials.md for the model.
fn physical_f0(surface: StandardSurface) -> vec3<f32> {
    let ratio = (surface.physical[0].x - 1.) / (surface.physical[0].x + 1.);
    return min(vec3(1.), surface.physical[1].rgb * ratio * ratio) * surface.physical[0].y;
}
fn physical_fresnel(cosine: f32, surface: StandardSurface) -> vec3<f32> {
    let f0 = physical_f0(surface);
    let regular=f0 + (vec3(surface.physical[0].y) - f0) * pow(1. - cosine, 5.);
    return iridescent_fresnel(cosine,f0,regular,surface);
}
fn maximum3(value: vec3<f32>) -> f32 { return max(value.x, max(value.y, value.z)); }
fn coat_fresnel(cosine: f32, surface: StandardSurface) -> f32 {
    return surface.physical[0].z * (.04 + .96 * pow(1. - cosine, 5.));
}
fn physical_tangent(n: vec3<f32>, authored: vec4<f32>, surface: StandardSurface) -> vec3<f32> {
    let axis = select(vec3(1.,0.,0.), vec3(0.,1.,0.), abs(n.x) > .9);
    let t = normalized_or(authored.xyz - n * dot(n, authored.xyz), normalized_or(cross(axis,n),axis));
    let b = cross(n,t) * select(1., authored.w, abs(authored.w) > .5);
    return t * cos(surface.physical[3].x) + b * sin(surface.physical[3].x);
}
fn ggx_distribution_visibility(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, t: vec3<f32>, roughness: f32, anisotropy: f32) -> f32 {
    let h = normalized_or(v+l,n);
    let b = cross(n,t);
    let alpha = max(roughness * roughness, .002025);
    // Elliptical GGX. At zero anisotropy this reduces to the standard lobe.
    let at = mix(alpha, 1., anisotropy * anisotropy);
    let ab = alpha;
    let nh = max(dot(n,h),0.); let nv = max(dot(n,v),0.); let nl = max(dot(n,l),0.);
    let q = vec3(dot(t,h)/at, dot(b,h)/ab, nh);
    let denominator = dot(q,q);
    let d = 1. / max(3.141592653589793 * at * ab * denominator * denominator, 1e-20);
    let lambda_v = nl * length(vec3(at * dot(t,v), ab * dot(b,v), nv));
    let lambda_l = nv * length(vec3(at * dot(t,l), ab * dot(b,l), nl));
    return d * .5 / max(lambda_v + lambda_l, 1e-12);
}
// Three.js r180 Charlie directional-albedo fit, with the irradiance pi folded in.
// Copyright three.js authors; MIT terms are in THIRD_PARTY_NOTICES.md.
fn sheen_albedo(cosine: f32, roughness: f32) -> f32 {
    let r = max(roughness, .045); let r2 = r*r;
    let a = select(-8.48*r2 + 14.3*r - 9.95, -339.2*r2 + 161.4*r - 25.9, r < .25);
    let b = select(1.97*r2 - 3.27*r + .72, 44.*r2 - 23.7*r + 3.26, r < .25);
    let tail = select(.1*(r-.25), 0., r < .25);
    return clamp(exp(a*cosine+b)+tail,0.,1.);
}
fn physical_direct(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, tangent: vec4<f32>, surface: StandardSurface) -> vec3<f32> {
    if (surface.physical[3].y == 0.) {
        return direct_brdf(n,v,l,surface.base.rgb,surface.metallic,surface.roughness);
    }
    let nl = max(dot(n,l),0.); let nv = max(dot(n,v),0.);

    let h = normalized_or(v+l,n); let vh = clamp(dot(v,h),0.,1.);
    let t = physical_tangent(n,tangent,surface);
    let dielectric = physical_fresnel(vh,surface);
    let metal_regular = surface.base.rgb + (vec3(1.)-surface.base.rgb) * pow(1.-vh,5.);
    let metal=iridescent_fresnel(vh,surface.base.rgb,metal_regular,surface);
    let fresnel = mix(dielectric,metal,surface.metallic);
    let diffuse = (1.-maximum3(dielectric)) * (1.-surface.metallic) * (1.-surface.transmission[0].x) * surface.base.rgb / 3.141592653589793;
    var base = diffuse + fresnel * ggx_distribution_visibility(n,v,l,t,surface.roughness,surface.physical[2].w);
    // Charlie distribution with Neubelt visibility for a soft cloth lobe.
    let inverse_alpha = 1. / max(surface.physical[1].w * surface.physical[1].w, .002025);
    let nh = clamp(dot(n,h),0.,1.);
    let charlie = (2.+inverse_alpha) * pow(max(1.-nh*nh,0.), inverse_alpha*.5) / (2.*3.141592653589793);
    let sheen = surface.physical[2].rgb;
    let sheen_energy = maximum3(sheen) * max(sheen_albedo(nv,surface.physical[1].w),sheen_albedo(nl,surface.physical[1].w));
    base = base * (1.-sheen_energy) + sheen * charlie / max(4.*(nl+nv-nl*nv),1e-12);
    let cn = surface.coat_normal;
    let coat_nv = max(dot(cn,v),0.); let coat_nl = max(dot(cn,l),0.);
    let coat = coat_fresnel(coat_nv,surface);
    let ct = physical_tangent(cn,tangent,surface);
    let base_light = select(vec3(0.),base*nl,nv>0.);
    let coating = select(0.,coat * ggx_distribution_visibility(cn,v,l,ct,surface.physical[0].w,0.) * coat_nl,coat_nv>0.);
    return base_light * (1.-coat) + vec3(coating);
}
fn physical_environment(n: vec3<f32>, v: vec3<f32>, tangent: vec4<f32>, surface: StandardSurface) -> vec3<f32> {
    if (surface.physical[3].y == 0.) { return shade_environment(n,v,surface); }
    if (environment.params.x == 0.) { return vec3(0.); }
    let nv = clamp(dot(n,v),0.,1.);
    let t = physical_tangent(n,tangent,surface);
    // Prefiltered GGX IBL uses a bent normal for the stretched reflection.
    let b = cross(n,t);
    let bent = normalized_or(cross(cross(b,v),b),n);
    let reflected = reflect(-v, normalized_or(mix(n,bent,surface.physical[2].w * (1.-surface.roughness)),n));
    let diffuse = textureSampleLevel(diffuse_environment,environment_sampler,environment_uv(n),0.).rgb;
    let radiance = textureSampleLevel(specular_environment,environment_sampler,environment_uv(reflected),surface.roughness*environment.params.y).rgb;
    let brdf = textureSampleLevel(environment_brdf,brdf_sampler,vec2(nv,surface.roughness),0.).rg;
    let f0 = mix(physical_f0(surface),surface.base.rgb,surface.metallic);
    let f90 = mix(surface.physical[0].y,1.,surface.metallic);
    var reflected_energy=f0*brdf.x+f90*brdf.y;
    if(surface.optical[0].x>0. && surface.optical[0].w>0.) {
        let film=film_fresnel(nv,f0,surface.optical[0].y,surface.optical[0].w);
        reflected_energy=mix(reflected_energy,film*(brdf.x+brdf.y),surface.optical[0].x);
    }
    var base = (1.-maximum3(physical_fresnel(nv,surface))) * (1.-surface.metallic) * (1.-surface.transmission[0].x) * surface.base.rgb * diffuse + radiance * reflected_energy;
    let sheen = surface.physical[2].rgb;
    let sheen_energy = sheen_albedo(nv,surface.physical[1].w);
    base = base * (1.-maximum3(sheen)*sheen_energy) + sheen * diffuse * sheen_energy;
    let coat_nv = clamp(dot(surface.coat_normal,v),0.,1.);
    let coat = textureSampleLevel(specular_environment,environment_sampler,environment_uv(reflect(-v,surface.coat_normal)),surface.physical[0].w*environment.params.y).rgb;
    let coat_brdf = textureSampleLevel(environment_brdf,brdf_sampler,vec2(coat_nv,surface.physical[0].w),0.).rg;
    return (base * (1.-coat_fresnel(coat_nv,surface)) + coat * surface.physical[0].z * (.04*coat_brdf.x+coat_brdf.y)) * environment.params.x * surface.occlusion;
}
