// Thin-film Fourier integration, adapted from Three.js r180 and the
// Belcour/Barla model used by KHR_materials_iridescence. MIT notice retained
// in THIRD_PARTY_NOTICES.md. Thickness is in nanometres.
fn film_sensitivity(path:f32, shift:vec3<f32>) -> vec3<f32> {
    let phase=6.283185307179586*path*1e-9;
    let amplitude=vec3(5.4856e-13,4.4201e-13,5.2481e-13);
    let frequency=vec3(1.6810e6,1.7953e6,2.2084e6);
    let variance=vec3(4.3278e9,9.3046e9,6.6121e9);
    var xyz=amplitude*sqrt(6.283185307179586*variance)*cos(frequency*phase+shift)*exp(-phase*phase*variance);
    xyz.x+=9.7470e-14*sqrt(6.283185307179586*4.5282e9)*cos(2.2399e6*phase+shift.x)*exp(-4.5282e9*phase*phase);
    xyz/=1.0685e-7;
    return mat3x3(vec3(3.2404542,-.969266,.0556434),vec3(-1.5371385,1.8760108,-.2040259),vec3(-.4985314,.041556,1.0572252))*xyz;
}
fn film_fresnel(cosine:f32, f0:vec3<f32>, film_ior:f32, thickness:f32) -> vec3<f32> {
    let eta=mix(1.,film_ior,smoothstep(0.,.03,thickness));
    let cos2_squared=1.-(1.-cosine*cosine)/(eta*eta);
    if(cos2_squared<0.) {return vec3(1.);}
    let cos2=sqrt(cos2_squared);
    let ratio=(eta-1.)/(eta+1.);
    let r0=ratio*ratio;
    let r12=r0+(1.-r0)*pow(1.-cosine,5.);
    let t=1.-r12;
    let root=sqrt(clamp(f0,vec3(0.),vec3(.9999)));
    let base_ior=(vec3(1.)+root)/(vec3(1.)-root);
    let ratio23=(base_ior-vec3(eta))/(base_ior+vec3(eta));
    let r1=ratio23*ratio23;
    let r23=r1+(vec3(1.)-r1)*pow(1.-cos2,5.);
    let phase=vec3(3.141592653589793)+select(vec3(0.),vec3(3.141592653589793),base_ior<vec3(eta));
    let path=2.*eta*thickness*cos2;
    let r123=clamp(r12*r23,vec3(1e-5),vec3(.9999));
    let root123=sqrt(r123);
    let rs=t*t*r23/(vec3(1.)-r123);
    var intensity=vec3(r12)+rs;
    var coefficient=rs-vec3(t);
    for(var order=1;order<=2;order++) {
        coefficient*=root123;
        intensity+=coefficient*2.*film_sensitivity(f32(order)*path,f32(order)*phase);
    }
    return clamp(intensity,vec3(0.),vec3(1.));
}
fn iridescent_fresnel(cosine:f32, f0:vec3<f32>, regular:vec3<f32>, surface:StandardSurface) -> vec3<f32> {
    if(!IRIDESCENCE || surface.optical[0].x<=0. || surface.optical[0].w<=0.) {return regular;}
    return mix(regular,film_fresnel(cosine,f0,surface.optical[0].y,surface.optical[0].w),surface.optical[0].x);
}
