// Runtime equations from Bruneton / three-geospatial; licenses/bruneton.txt.
// Lengths inside these functions are kilometres. Inputs and outputs are linear.
const atmosphereRuntimeWgsl = r'''
struct AtmosphereSample { radiance:vec3<f32>, transmittance:vec3<f32> }
fn emptyAtmosphere()->AtmosphereSample {return AtmosphereSample(vec3<f32>(0.),vec3<f32>(1.));}
fn totalScattering(r:f32,mu:f32,mus:f32,nu:f32,ground:bool)->vec3<f32> {
 let ray=scattering(atmosphereRayleigh,r,mu,mus,nu,ground);
 let mi=scattering(atmosphereMie,r,mu,mus,nu,ground);
 let higher=scattering(atmosphereHigher,r,mu,mus,nu,ground);
 return (ray+higher)*rayPhase(nu)+mi*miePhase(nu);
}
fn atmosphereSunIrradiance(point:vec3<f32>,normal:vec3<f32>,sun:vec3<f32>)->vec3<f32> {
 let r=radius(length(point));let mus=cosine(dot(point,sun)/max(length(point),1e-6));
 return SOLAR*SUN_LUMINANCE*transSun(atmosphereTransmittance,r,mus)*max(dot(normal,sun),0.);
}
fn atmosphereSkyIrradiance(point:vec3<f32>,normal:vec3<f32>,sun:vec3<f32>)->vec3<f32> {
 let r=radius(length(point));let mus=cosine(dot(point,sun)/max(length(point),1e-6));
 return irradiance(atmosphereIrradiance,r,mus)*SKY_LUMINANCE*(1.+dot(normal,normalize(point)))*.5;
}
// Both intersections are ordered along the normalized ray. A negative
// discriminant is checked by the caller, not replaced with a false tangent.
fn sphereInterval(origin:vec3<f32>,ray:vec3<f32>,rad:f32)->vec2<f32> {
 let b=dot(origin,ray);let disc=b*b-dot(origin,origin)+rad*rad;
 let root=safeSqrt(disc);return vec2<f32>(-b-root,-b+root);
}
fn atmosphereSky(origin:vec3<f32>,ray:vec3<f32>,sun:vec3<f32>,groundColor:bool)->AtmosphereSample {
 var camera=origin;var r=length(camera);let b=dot(camera,ray);
 let disc=b*b-r*r+TOP*TOP;if(disc<0.){return emptyAtmosphere();}
 let outer=sphereInterval(camera,ray,TOP);
 if(outer.y<=0.){return emptyAtmosphere();}
 if(r>TOP){camera+=ray*max(outer.x,0.);r=TOP;}
 if(r<BOTTOM){camera+=ray*sphereInterval(camera,ray,BOTTOM).y;r=BOTTOM;}
 r=radius(r);let mu=cosine(dot(camera,ray)/r);let mus=cosine(dot(camera,sun)/r);let nu=cosine(dot(ray,sun));
 let ground=hitsGround(r,mu);var tr=transTop(atmosphereTransmittance,r,mu);
 var radiance=totalScattering(r,mu,mus,nu,ground)*SKY_LUMINANCE;
 if(ground){
   if(groundColor){
     let distance=groundDistance(r,mu);let point=camera+ray*distance;let normal=normalize(point);
     let light=atmosphereSunIrradiance(point,normal,sun)+atmosphereSkyIrradiance(point,normal,sun);
     radiance+=transPath(atmosphereTransmittance,r,mu,distance,true)*ALBEDO/PI*light;
   }
   tr=vec3<f32>(0.);
 }
 return AtmosphereSample(max(radiance,vec3<f32>(0.)),tr);
}
fn atmosphereSegment(origin:vec3<f32>,point:vec3<f32>,sun:vec3<f32>)->AtmosphereSample {
 let offset=point-origin;let distance=length(offset);
 if(distance<=1e-6){return emptyAtmosphere();}let ray=offset/distance;
 let b=dot(origin,ray);let r0=length(origin);
 if(b*b-r0*r0+TOP*TOP<0.){return emptyAtmosphere();}
 let outer=sphereInterval(origin,ray,TOP);var start=max(0.,outer.x);var end=min(distance,outer.y);
 if(end<=start){return emptyAtmosphere();}
 let innerDisc=b*b-r0*r0+BOTTOM*BOTTOM;
 if(innerDisc>=0.){
   let inner=sphereInterval(origin,ray,BOTTOM);
   if(r0<BOTTOM){start=max(start,inner.y);}
   else if(inner.x>=start){end=min(end,inner.x);}
 }
 if(end<=start){return emptyAtmosphere();}
 let camera=origin+ray*start;let d=end-start;let r=radius(length(camera));
 let mu=cosine(dot(camera,ray)/r);let mus=cosine(dot(camera,sun)/r);let nu=cosine(dot(ray,sun));let ground=hitsGround(r,mu);
 let tr=transPath(atmosphereTransmittance,r,mu,d,ground);
 let rp=radius(safeSqrt(d*d+2.*r*mu*d+r*r));let mup=cosine((r*mu+d)/rp);let musp=cosine((r*mus+d*nu)/rp);
 let ray0=scattering(atmosphereRayleigh,r,mu,mus,nu,ground);let ray1=scattering(atmosphereRayleigh,rp,mup,musp,nu,ground);
 let high0=scattering(atmosphereHigher,r,mu,mus,nu,ground);let high1=scattering(atmosphereHigher,rp,mup,musp,nu,ground);
 let mie0=scattering(atmosphereMie,r,mu,mus,nu,ground);let mie1=scattering(atmosphereMie,rp,mup,musp,nu,ground);
 // Retain the source's fade of single Mie scattering under the horizon.
 let radiance=((ray0+high0-tr*(ray1+high1))*rayPhase(nu)+(mie0-tr*mie1)*miePhase(nu)*smoothstep(0.,.01,mus))*SKY_LUMINANCE;
 return AtmosphereSample(max(radiance,vec3<f32>(0.)),tr);
}
''';
