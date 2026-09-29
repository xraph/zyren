// LTC tables: Heitz, Dupuy, Hill and Neubelt, SIGGRAPH 2016. See ltc/LICENSE.
@group(0) @binding(11) var ltc_matrix: texture_2d<f32>;
@group(0) @binding(12) var ltc_amplitude: texture_2d<f32>;
fn ltc_lookup(table: texture_2d<f32>, roughness: f32, nv: f32) -> vec4<f32> {
    let uv = vec2(clamp(roughness,0.,1.), sqrt(1.-clamp(nv,0.,1.))) * 63.;
    let lo = vec2<i32>(uv); let hi = min(lo + vec2(1), vec2(63)); let f = fract(uv);
    return mix(mix(textureLoad(table,lo,0),textureLoad(table,vec2(hi.x,lo.y),0),f.x),
        mix(textureLoad(table,vec2(lo.x,hi.y),0),textureLoad(table,hi,0),f.x),f.y);
}
fn ltc_polygon(points: array<vec3<f32>,4>, transform: mat3x3<f32>) -> f32 {
    var corners: array<vec3<f32>,4>;
    for (var i=0u;i<4u;i++) { corners[i] = transform * points[i]; }
    // Clip against the cosine hemisphere before normalizing to the unit sphere.
    var clipped: array<vec3<f32>,5>; var count=0u;
    for (var i=0u;i<4u;i++) {
        let a=corners[i]; let b=corners[(i+1u)%4u];
        if (a.z > 0.) { clipped[count]=a; count++; }
        if ((a.z > 0.) != (b.z > 0.)) {
            clipped[count]=mix(a,b,a.z/(a.z-b.z)); count++;
        }
    }
    if (count < 3u) { return 0.; }
    var integral=vec3(0.);
    for (var i=0u;i<count;i++) {
        let a=normalized_or(clipped[i],vec3(0.,0.,1.));
        let b=normalized_or(clipped[(i+1u)%count],vec3(0.,0.,1.));
        let edge=cross(a,b); let sine=length(edge);
        integral += edge * (atan2(sine,clamp(dot(a,b),-1.,1.)) / max(sine,1e-10));
    }
    return clamp(abs(integral.z)/(2.*3.141592653589793),0.,1.);
}
fn ltc_transform(roughness: f32, nv: f32) -> mat3x3<f32> {
    let m=ltc_lookup(ltc_matrix,roughness,nv);
    return mat3x3(vec3(m.x,0.,m.y),vec3(0.,1.,0.),vec3(m.z,0.,m.w));
}
// Anisotropic GGX needs a directional fit with more than two LUT dimensions.
// Integrate the authored BRDF with bounded Gauss-Legendre quadrature instead.
fn anisotropic_area(light: AreaLight, center: vec3<f32>, n: vec3<f32>, v: vec3<f32>, tangent: vec4<f32>, surface: StandardSurface) -> vec3<f32> {
    let nodes=array<f32,8>(-.960289856,-.796666477,-.52553241,-.183434642,.183434642,.52553241,.796666477,.960289856);
    let weights=array<f32,8>(.101228536,.222381034,.313706646,.362683783,.362683783,.313706646,.222381034,.101228536);
    let area_vector=cross(light.half_width.xyz,light.half_height.xyz);
    var result=vec3(0.);
    for (var y=0u;y<8u;y++) { for (var x=0u;x<8u;x++) {
        let offset=center+light.half_width.xyz*nodes[x]+light.half_height.xyz*nodes[y];
        let r2=dot(offset,offset); let l=offset*inverseSqrt(max(r2,1e-20));
        let solid_angle=max(dot(area_vector,l),0.)/max(r2,1e-20);
        result+=physical_direct(n,v,l,tangent,surface)*solid_angle*weights[x]*weights[y];
    } }
    return result*light.color_intensity.rgb*light.color_intensity.w;
}
fn shade_area(light: AreaLight, position: vec3<f32>, n: vec3<f32>, v: vec3<f32>, tangent: vec4<f32>, surface: StandardSurface) -> vec3<f32> {
    let center=light.position.xyz-position;
    let w=light.half_width.xyz; let h=light.half_height.xyz;
    if (dot(cross(w,h),center) <= 0. || dot(n,v) <= 0.) { return vec3(0.); }
    if (surface.physical[3].y != 0. && (surface.physical[2].w > 0. || surface.optical[0].x > 0.)) {
        return anisotropic_area(light,center,n,v,tangent,surface);
    }
    let axis=select(vec3(1.,0.,0.),vec3(0.,1.,0.),abs(n.x)>.9);
    let t=normalized_or(v-n*dot(n,v),normalized_or(cross(axis,n),axis));
    let basis=transpose(mat3x3(t,cross(n,t),n));
    let points=array<vec3<f32>,4>(basis*(center-w-h),basis*(center+w-h),basis*(center+w+h),basis*(center-w+h));
    let identity=mat3x3(vec3(1.,0.,0.),vec3(0.,1.,0.),vec3(0.,0.,1.));
    let diffuse_integral=ltc_polygon(points,identity);
    let nv=clamp(dot(n,v),0.,1.);
    let physical=surface.physical[3].y != 0.;
    let dielectric=select(vec3(.04),physical_f0(surface),physical);
    let f0=mix(dielectric,surface.base.rgb,surface.metallic);
    let f90=mix(select(1.,surface.physical[0].y,physical),1.,surface.metallic);
    let amplitude=ltc_lookup(ltc_amplitude,surface.roughness,nv);
    let specular_integral=ltc_polygon(points,ltc_transform(surface.roughness,nv));
    var color=surface.base.rgb*(1.-surface.metallic)*(1.-surface.transmission[0].x)*(1.-maximum3(dielectric))*diffuse_integral
        + (f0*amplitude.x+(vec3(f90)-f0)*amplitude.y)*specular_integral;
    if (physical) {
        // Smooth cloth response and energy reduction use the hemispherical fit.
        let sheen=surface.physical[2].rgb;
        let sheen_energy=sheen_albedo(nv,surface.physical[1].w);
        color=color*(1.-maximum3(sheen)*sheen_energy)+sheen*diffuse_integral*sheen_energy;
        let cn=surface.coat_normal;
        let coat_nv=clamp(dot(cn,v),0.,1.);
        let coat_axis=select(vec3(1.,0.,0.),vec3(0.,1.,0.),abs(cn.x)>.9);
        let ct=normalized_or(v-cn*dot(cn,v),normalized_or(cross(coat_axis,cn),coat_axis));
        let coat_basis=transpose(mat3x3(ct,cross(cn,ct),cn));
        let coat_points=array<vec3<f32>,4>(coat_basis*(center-w-h),coat_basis*(center+w-h),coat_basis*(center+w+h),coat_basis*(center-w+h));
        let coat_amplitude=ltc_lookup(ltc_amplitude,surface.physical[0].w,coat_nv);
        let coat_integral=ltc_polygon(coat_points,ltc_transform(surface.physical[0].w,coat_nv));
        color=color*(1.-coat_fresnel(coat_nv,surface))+vec3(surface.physical[0].z*(.04*coat_amplitude.x+.96*coat_amplitude.y)*coat_integral);
    }
    return color*light.color_intensity.rgb*light.color_intensity.w;
}
