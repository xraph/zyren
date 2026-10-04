override PHYSICAL: bool = true;
override COAT: bool = true;
override SHEEN: bool = true;
override ANISOTROPY: bool = true;
override IRIDESCENCE: bool = true;
override TRANSMISSION: bool = true;
override DISPERSION: bool = true;
// Layered reflectance. See doc/physical-materials.md for the model.
fn physical_f0(surface: StandardSurface) -> vec3<f32> {
    let ratio = (surface.physical[0].x - 1.) / (surface.physical[0].x + 1.);
    return min(vec3(1.), surface.physical[1].rgb * ratio * ratio) * surface.physical[0].y;
}
fn physical_fresnel(cosine: f32, surface: StandardSurface) -> vec3<f32> {
    let f0 = physical_f0(surface);
    let regular=f0 + (vec3(surface.physical[0].y) - f0) * pow(1. - cosine, 5.);
    return iridescent_fresnel(cosine,f0,regular,surface);
}
fn physical_diffuse_budget(nv: f32, brdf: vec2<f32>, surface: StandardSurface) -> f32 {
    let f0 = physical_f0(surface);
    var energy = f0 * brdf.x + vec3(surface.physical[0].y * brdf.y);
    var effective = f0;
    if (IRIDESCENCE && surface.optical[0].w > 0.) {
        let film = film_fresnel(nv,f0,surface.optical[0].y,surface.optical[0].w);
        energy = mix(energy,film*(brdf.x+brdf.y),surface.optical[0].x);
        effective = mix(effective,film,surface.optical[0].x);
    }
    return clamp(1.-maximum3(energy*energy_scale(effective,brdf)),0.,1.);
}
fn maximum3(value: vec3<f32>) -> f32 { return max(value.x, max(value.y, value.z)); }
fn coat_fresnel(cosine: f32, surface: StandardSurface) -> f32 {
    return surface.physical[0].z * (.04 + .96 * pow(1. - cosine, 5.));
}
fn physical_tangent(n: vec3<f32>, authored: vec4<f32>, surface: StandardSurface) -> vec3<f32> {
    let axis = select(vec3(1.,0.,0.), vec3(0.,1.,0.), abs(n.x) > .9);
    let t = normalized_or(authored.xyz - n * dot(n, authored.xyz), normalized_or(cross(axis,n),axis));
    let b = cross(n,t) * select(1., authored.w, abs(authored.w) > .5);
    if (!ANISOTROPY) { return t; }
    return t * cos(surface.physical[3].x) + b * sin(surface.physical[3].x);
}
struct GgxView {
    t: vec3<f32>, b: vec3<f32>, at: f32, ab: f32, nv: f32, view_length: f32,
}
fn prepare_ggx(n: vec3<f32>, v: vec3<f32>, t: vec3<f32>, roughness: f32, anisotropy: f32) -> GgxView {
    let b = cross(n,t);
    let alpha = max(roughness * roughness, .002025);
    // Elliptical GGX. At zero anisotropy this reduces to the standard lobe.
    let at = mix(alpha, 1., anisotropy * anisotropy);
    let ab = alpha;
    let nv = max(dot(n,v),0.);
    return GgxView(t,b,at,ab,nv,length(vec3(at * dot(t,v), ab * dot(b,v), nv)));
}
fn ggx_prepared(n: vec3<f32>, l: vec3<f32>, h: vec3<f32>, view: GgxView) -> f32 {
    let nh = max(dot(n,h),0.); let nl = max(dot(n,l),0.);
    let q = vec3(dot(view.t,h)/view.at, dot(view.b,h)/view.ab, nh);
    let denominator = dot(q,q);
    let d = 1. / max(3.141592653589793 * view.at * view.ab * denominator * denominator, 1e-20);
    let lambda_v = nl * view.view_length;
    let lambda_l = view.nv * length(vec3(view.at * dot(view.t,l), view.ab * dot(view.b,l), nl));
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
struct PhysicalView {
    base: GgxView, coat: GgxView,
    inverse_sheen_alpha: f32, sheen_view_albedo: f32, coat_fresnel: f32,
    energy: vec3<f32>, diffuse_weight: f32, coat_energy: f32,
}
fn prepare_physical(n: vec3<f32>, v: vec3<f32>, tangent: vec4<f32>, surface: StandardSurface) -> PhysicalView {
    let base = prepare_ggx(n,v,physical_tangent(n,tangent,surface),surface.roughness,surface.physical[2].w);
    var view: PhysicalView;
    view.base = base;
    let effective_roughness = sqrt(sqrt(base.at * base.ab));
    let brdf = energy_brdf(base.nv,effective_roughness);
    let dielectric = physical_f0(surface);
    var f0 = mix(dielectric,surface.base.rgb,surface.metallic);
    if (IRIDESCENCE) { f0 = iridescent_fresnel(base.nv,f0,f0,surface); }
    view.energy = energy_scale(f0,brdf);
    view.diffuse_weight = physical_diffuse_budget(base.nv,brdf,surface);
    if (COAT) {
        let cn = surface.coat_normal;
        view.coat = prepare_ggx(cn,v,physical_tangent(cn,tangent,surface),surface.physical[0].w,0.);
        let coat_brdf = energy_brdf(view.coat.nv,surface.physical[0].w);
        view.coat_energy = energy_scale(vec3(.04),coat_brdf).x;
        view.coat_fresnel = surface.physical[0].z * (1.-diffuse_budget(vec3(.04),1.,coat_brdf));
    }
    if (SHEEN) {
        view.inverse_sheen_alpha = 1. / max(surface.physical[1].w * surface.physical[1].w,.002025);
        view.sheen_view_albedo = sheen_albedo(base.nv,surface.physical[1].w);
    }
    return view;
}
fn physical_direct_prepared(n: vec3<f32>, v: vec3<f32>, l: vec3<f32>, surface: StandardSurface, view: PhysicalView) -> vec3<f32> {
    let nl = max(dot(n,l),0.); let nv = view.base.nv;
    let h = normalized_or(v+l,n); let vh = clamp(dot(v,h),0.,1.);
    var dielectric = vec3(0.);
    if (surface.metallic < 1.) { dielectric = physical_fresnel(vh,surface); }
    var fresnel = dielectric;
    if (surface.metallic > 0.) {
        let metal_regular = surface.base.rgb + (vec3(1.)-surface.base.rgb) * pow(1.-vh,5.);
        let metal = iridescent_fresnel(vh,surface.base.rgb,metal_regular,surface);
        fresnel = mix(dielectric,metal,surface.metallic);
    }
    let diffuse = view.diffuse_weight * (1.-surface.metallic) * (1.-surface.transmission[0].x) * surface.base.rgb / 3.141592653589793;
    var base = diffuse + fresnel * ggx_prepared(n,l,h,view.base) * view.energy;
    if (SHEEN) {
    // Charlie distribution with Neubelt visibility for a soft cloth lobe.
    let inverse_alpha = view.inverse_sheen_alpha;
    let nh = clamp(dot(n,h),0.,1.);
    let charlie = (2.+inverse_alpha) * pow(max(1.-nh*nh,0.), inverse_alpha*.5) / (2.*3.141592653589793);
    let sheen = surface.physical[2].rgb;
    let sheen_energy = maximum3(sheen) * max(view.sheen_view_albedo,sheen_albedo(nl,surface.physical[1].w));
    base = base * (1.-sheen_energy) + sheen * charlie / max(4.*(nl+nv-nl*nv),1e-12);
    }
    if (!COAT) { return select(vec3(0.),base*nl,nv>0.); }
    let cn = surface.coat_normal;
    let coat_nv = view.coat.nv; let coat_nl = max(dot(cn,l),0.);
    let coat = view.coat_fresnel;
    let base_light = select(vec3(0.),base*nl,nv>0.);
    let coat_h = normalized_or(v+l,cn);
    let coating = select(0.,surface.physical[0].z * (.04 + .96 * pow(1.-vh,5.)) * view.coat_energy * ggx_prepared(cn,l,coat_h,view.coat) * coat_nl,coat_nv>0.);
    return base_light * (1.-coat) + vec3(coating);
}
fn physical_environment(n: vec3<f32>, v: vec3<f32>, tangent: vec4<f32>, surface: StandardSurface, view: PhysicalView) -> vec3<f32> {
    if (!PHYSICAL) { return shade_environment(n,v,surface); }
    if (environment.params.x == 0.) { return vec3(0.); }
    let nv = clamp(dot(n,v),0.,1.);
    var reflected = reflect(-v,n);
    if (ANISOTROPY) {
        let t = physical_tangent(n,tangent,surface);
        // Prefiltered GGX IBL approximates the stretched reflection with a bent normal.
        let b = cross(n,t);
        let bent = normalized_or(cross(cross(b,v),b),n);
        reflected = reflect(-v, normalized_or(mix(n,bent,surface.physical[2].w * (1.-surface.roughness)),n));
    }
    let diffuse = textureSampleLevel(diffuse_environment,environment_sampler,environment_uv(n),0.).rgb / select(1.,3.141592653589793,environment.params.z>.5);
    let radiance = environment_specular(reflected,surface.roughness);
    let brdf = energy_brdf(nv,sqrt(sqrt(view.base.at*view.base.ab)));
    let f0 = mix(physical_f0(surface),surface.base.rgb,surface.metallic);
    let f90 = mix(surface.physical[0].y,1.,surface.metallic);
    var reflected_energy=f0*brdf.x+f90*brdf.y;
    if(IRIDESCENCE && surface.optical[0].x>0. && surface.optical[0].w>0.) {
        let film=film_fresnel(nv,f0,surface.optical[0].y,surface.optical[0].w);
        reflected_energy=mix(reflected_energy,film*(brdf.x+brdf.y),surface.optical[0].x);
    }
    var base = view.diffuse_weight * (1.-surface.metallic) * (1.-surface.transmission[0].x) * surface.base.rgb * diffuse + radiance * reflected_energy * view.energy;
    if (SHEEN) {
    let sheen = surface.physical[2].rgb;
    let sheen_energy = sheen_albedo(nv,surface.physical[1].w);
    base = base * (1.-maximum3(sheen)*sheen_energy) + sheen * diffuse * sheen_energy;
    }
    if (!COAT) { return base * environment.params.x * surface.occlusion; }
    let coat_nv = clamp(dot(surface.coat_normal,v),0.,1.);
    let coat = environment_specular(reflect(-v,surface.coat_normal),surface.physical[0].w);
    let coat_brdf = energy_brdf(coat_nv,surface.physical[0].w);
    return (base * (1.-view.coat_fresnel) + coat * surface.physical[0].z * (.04*coat_brdf.x+coat_brdf.y) * view.coat_energy) * environment.params.x * surface.occlusion;
}
