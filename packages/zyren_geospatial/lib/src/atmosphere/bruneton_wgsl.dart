// Derived from the supplied three-geospatial Bruneton common/precompute shaders.
// Copyright (c) 2017 Eric Bruneton; Copyright (c) 2008 INRIA.
// Redistribution terms and disclaimer: licenses/bruneton.txt.
import 'parameters.dart';
import 'quality.dart';

String atmosphereDefinitions(AtmosphereParameters a, AtmosphereQuality q) {
  String scalar(String name, double value) => 'const $name: f32 = $value;\n';
  String vector(String name, List<double> v) =>
      'const $name = vec3<f32>(${v.join(',')});\n';
  String profile(String name, DensityProfile p) {
    String layer(DensityLayer l) {
      final v = l.shaderValues;
      return 'clamp(${v[1]}*exp(${v[2]}*h)+${v[3]}*h+${v[4]},0.,1.)';
    }

    return 'fn $name(h:f32)->f32 { if(h<${p.lower.width * .001}){return ${layer(p.lower)};}return ${layer(p.upper)};}\n';
  }

  return '${scalar('BOTTOM', a.bottomRadius * .001)}'
      '${scalar('TOP', a.topRadius * .001)}'
      '${scalar('SUN_RADIUS', a.sunAngularRadius)}'
      '${scalar('MIN_SUN', a.minCosSun)}'
      '${scalar('MIE_G', a.miePhaseFunctionG)}'
      '${vector('SOLAR', a.solarIrradiance.storage)}'
      '${vector('RAYLEIGH', (a.rayleighScattering * 1000).storage)}'
      '${vector('MIE', (a.mieScattering * 1000).storage)}'
      '${vector('MIE_EXT', (a.mieExtinction * 1000).storage)}'
      '${vector('ABSORPTION', (a.absorptionExtinction * 1000).storage)}'
      '${vector('ALBEDO', a.groundAlbedo.storage)}'
      '${vector('SUN_LUMINANCE', a.sunRelativeLuminance.storage)}'
      '${vector('SKY_LUMINANCE', a.skyRelativeLuminance.storage)}'
      '${profile('rayDensity', a.rayleighDensity)}'
      '${profile('mieDensity', a.mieDensity)}'
      '${profile('absorptionDensity', a.absorptionDensity)}'
      'const T_SIZE = vec2<f32>(${q.transmittanceWidth}.,${q.transmittanceHeight}.);\n'
      'const I_SIZE = vec2<f32>(${q.irradianceWidth}.,${q.irradianceHeight}.);\n'
      'const R_SIZE: f32 = ${q.radiusSize}.;\n'
      'const MU_SIZE: f32 = ${q.viewSize}.;\n'
      'const MUS_SIZE: f32 = ${q.sunSize}.;\n'
      'const NU_SIZE: f32 = ${q.angleSize}.;\n';
}

const atmosphereCommonWgsl = r'''
const PI: f32 = 3.141592653589793;
fn safeSqrt(x:f32)->f32 {return sqrt(max(x,0.));}
fn cosine(x:f32)->f32 {return clamp(x,-1.,1.);}
fn radius(x:f32)->f32 {return clamp(x,BOTTOM,TOP);}
fn topDistance(r:f32,mu:f32)->f32 {return max(0.,-r*mu+safeSqrt((r*mu)*(r*mu)+(TOP-r)*(TOP+r)));}
fn groundDistance(r:f32,mu:f32)->f32 {return max(0.,-r*mu-safeSqrt((r*mu)*(r*mu)-(r-BOTTOM)*(r+BOTTOM)));}
fn hitsGround(r:f32,mu:f32)->bool {return mu<0. && (r*mu)*(r*mu)-(r-BOTTOM)*(r+BOTTOM)>=0.;}
fn boundary(r:f32,mu:f32,ground:bool)->f32 {if(ground){return groundDistance(r,mu);}return topDistance(r,mu);}
fn unitCoord(x:f32,size:f32)->f32 {return .5/size+x*(1.-1./size);}
fn coordUnit(u:f32,size:f32)->f32 {return (u-.5/size)/(1.-1./size);}
fn rayPhase(nu:f32)->f32 {return 3./(16.*PI)*(1.+nu*nu);}
fn miePhase(nu:f32)->f32 {return 3./(8.*PI)*(1.-MIE_G*MIE_G)/(2.+MIE_G*MIE_G)*(1.+nu*nu)/pow(1.+MIE_G*MIE_G-2.*MIE_G*nu,1.5);}
fn sample2(t:texture_2d<f32>,uv:vec2<f32>)->vec3<f32> {
 let size=vec2<i32>(textureDimensions(t));let p=uv*vec2<f32>(size)-.5;let i=vec2<i32>(floor(p));let f=fract(p);let hi=size-1;
 return mix(mix(textureLoad(t,clamp(i,vec2<i32>(0),hi),0).rgb,textureLoad(t,clamp(i+vec2<i32>(1,0),vec2<i32>(0),hi),0).rgb,f.x),
 mix(textureLoad(t,clamp(i+vec2<i32>(0,1),vec2<i32>(0),hi),0).rgb,textureLoad(t,clamp(i+vec2<i32>(1,1),vec2<i32>(0),hi),0).rgb,f.x),f.y);
}
fn sample3(t:texture_3d<f32>,uv:vec3<f32>)->vec3<f32> {
 let size=vec3<i32>(textureDimensions(t));let p=uv*vec3<f32>(size)-.5;let i=vec3<i32>(floor(p));let f=fract(p);let hi=size-1;var sum=vec3<f32>(0.);
 for(var z=0;z<2;z++){for(var y=0;y<2;y++){for(var x=0;x<2;x++){
 let w=select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1)*select(1.-f.z,f.z,z==1);
 sum+=textureLoad(t,clamp(i+vec3<i32>(x,y,z),vec3<i32>(0),hi),0).rgb*w;
 }}}return sum;
}
fn transmittanceUv(r:f32,mu:f32)->vec2<f32> {
 let h=sqrt((TOP-BOTTOM)*(TOP+BOTTOM));let rho=safeSqrt((r-BOTTOM)*(r+BOTTOM));
 let d=topDistance(r,mu);let dmin=TOP-r;let dmax=rho+h;
 return vec2<f32>(unitCoord((d-dmin)/(dmax-dmin),T_SIZE.x),unitCoord(rho/h,T_SIZE.y));
}
fn transmittanceCoord(uv:vec2<f32>)->vec2<f32> {
 let xm=coordUnit(uv.x,T_SIZE.x);let xr=coordUnit(uv.y,T_SIZE.y);let h=sqrt((TOP-BOTTOM)*(TOP+BOTTOM));let rho=h*xr;
 let r=sqrt(rho*rho+BOTTOM*BOTTOM);let dmin=TOP-r;let dmax=rho+h;let d=dmin+xm*(dmax-dmin);
 var mu=1.;if(d>0.){mu=cosine((h*h-rho*rho-d*d)/(2.*r*d));}if(uv.x<=.5/T_SIZE.x){mu=1.;}return vec2<f32>(r,mu);
}
fn transTop(t:texture_2d<f32>,r:f32,mu:f32)->vec3<f32> {return sample2(t,transmittanceUv(r,mu));}
fn transPath(t:texture_2d<f32>,r:f32,mu:f32,d:f32,ground:bool)->vec3<f32> {
 if(d<=0.){return vec3<f32>(1.);}let rd=radius(safeSqrt(d*d+2.*r*mu*d+r*r));let md=cosine((r*mu+d)/rd);
 var numerator=transTop(t,r,mu);var denominator=transTop(t,rd,md);
 if(ground){numerator=transTop(t,rd,-md);denominator=transTop(t,r,-mu);}
 return clamp(numerator/max(denominator,vec3<f32>(1e-30)),vec3<f32>(0.),vec3<f32>(1.));
}
fn transSun(t:texture_2d<f32>,r:f32,mus:f32)->vec3<f32> {
 let s=BOTTOM/r;let c=-safeSqrt(1.-s*s);return transTop(t,r,mus)*smoothstep(-s*SUN_RADIUS,s*SUN_RADIUS,mus-c);
}
struct ScatterCoord {r:f32,mu:f32,mus:f32,nu:f32,ground:bool}
fn scatteringCoord(frag:vec3<f32>)->ScatterCoord {
 let uv=vec4<f32>(floor(frag.x/MUS_SIZE)/(NU_SIZE-1.),(frag.x%MUS_SIZE)/MUS_SIZE,frag.y/MU_SIZE,frag.z/R_SIZE);
 let h=sqrt((TOP-BOTTOM)*(TOP+BOTTOM));let rho0=h*coordUnit(uv.w,R_SIZE);var r=sqrt(rho0*rho0+BOTTOM*BOTTOM);if(frag.z==.5){r=BOTTOM;}if(frag.z==R_SIZE-.5){r=TOP;}let rho=safeSqrt((r-BOTTOM)*(r+BOTTOM));var mu=0.;let ground=uv.z<.5;
 if(ground){let dmin=r-BOTTOM;let dmax=rho;let d=dmin+(dmax-dmin)*coordUnit(1.-2.*uv.z,MU_SIZE/2.);mu=-1.;if(d>0.){mu=cosine(-(rho*rho+d*d)/(2.*r*d));}}
 else{let dmin=TOP-r;let dmax=rho+h;let d=dmin+(dmax-dmin)*coordUnit(2.*uv.z-1.,MU_SIZE/2.);mu=1.;if(d>0.){mu=cosine((h*h-rho*rho-d*d)/(2.*r*d));}}
 let x=coordUnit(uv.y,MUS_SIZE);let dmin=TOP-BOTTOM;let dmax=h;let cap=(topDistance(BOTTOM,MIN_SUN)-dmin)/(dmax-dmin);
 let a=(cap-x*cap)/(1.+x*cap);let d=dmin+min(a,cap)*(dmax-dmin);var mus=1.;if(d>0.){mus=cosine((h*h-d*d)/(2.*BOTTOM*d));}
 // These texel centres are exactly vertical. Evaluating their zero-distance
 // inverse mapping with fused f32 operations can turn the top boundary into
 // a spurious inward ray. Preserve the analytic endpoint before dividing.
 if(frag.y==MU_SIZE*.5+.5){mu=1.;}
 if(frag.y==MU_SIZE*.5-.5){mu=-1.;}
 if(frag.y==.5 || frag.y==MU_SIZE-.5){mu=-rho/r;}
 let spread=safeSqrt((1.-mu*mu)*(1.-mus*mus));let nu=clamp(cosine(uv.x*2.-1.),mu*mus-spread,mu*mus+spread);
 return ScatterCoord(r,mu,mus,nu,ground);
}
fn scatteringUv(r:f32,mu:f32,mus:f32,nu:f32,ground:bool)->vec4<f32> {
 let h=sqrt((TOP-BOTTOM)*(TOP+BOTTOM));let rho=safeSqrt((r-BOTTOM)*(r+BOTTOM));let ur=unitCoord(rho/h,R_SIZE);let rm=r*mu;let disc=rm*rm-(r-BOTTOM)*(r+BOTTOM);var um=0.;
 if(ground){let d=-rm-safeSqrt(disc);let dmin=r-BOTTOM;let dmax=rho;var x=0.;if(dmax!=dmin){x=(d-dmin)/(dmax-dmin);}um=.5-.5*unitCoord(x,MU_SIZE/2.);}
 else{let d=-rm+safeSqrt(disc+h*h);let dmin=TOP-r;let dmax=rho+h;um=.5+.5*unitCoord((d-dmin)/(dmax-dmin),MU_SIZE/2.);}
 let dmin=TOP-BOTTOM;let dmax=h;let a=(topDistance(BOTTOM,mus)-dmin)/(dmax-dmin);let cap=(topDistance(BOTTOM,MIN_SUN)-dmin)/(dmax-dmin);
 let us=unitCoord(max(1.-a/cap,0.)/(1.+a),MUS_SIZE);return vec4<f32>((nu+1.)*.5,us,um,ur);
}
fn scattering(t:texture_3d<f32>,r:f32,mu:f32,mus:f32,nu:f32,ground:bool)->vec3<f32> {
 let uv=scatteringUv(r,mu,mus,nu,ground);let x=uv.x*(NU_SIZE-1.);let i=floor(x);let f=x-i;
 return mix(sample3(t,vec3<f32>((i+uv.y)/NU_SIZE,uv.z,uv.w)),sample3(t,vec3<f32>((i+1.+uv.y)/NU_SIZE,uv.z,uv.w)),f);
}
fn irradianceUv(r:f32,mus:f32)->vec2<f32> {return vec2<f32>(unitCoord(mus*.5+.5,I_SIZE.x),unitCoord((r-BOTTOM)/(TOP-BOTTOM),I_SIZE.y));}
fn irradianceCoord(uv:vec2<f32>)->vec2<f32> {return vec2<f32>(BOTTOM+coordUnit(uv.y,I_SIZE.y)*(TOP-BOTTOM),cosine(2.*coordUnit(uv.x,I_SIZE.x)-1.));}
fn irradiance(t:texture_2d<f32>,r:f32,mus:f32)->vec3<f32> {return sample2(t,irradianceUv(r,mus));}
''';
