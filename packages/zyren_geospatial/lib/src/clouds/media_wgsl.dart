import 'quality.dart';

// Source cloud media and structured volume sampling, in metres.
String cloudMediaMathWgsl(CloudQuality quality) =>
    '''
const CLOUD_DETAIL:bool=${quality.shapeDetail};
const CLOUD_TURBULENCE:bool=${quality.turbulence};
const CLOUD_ACCURATE_PHASE:bool=${quality.clouds.accuratePhaseFunction};
const CLOUD_OCTAVES:u32=${quality.clouds.multiScatteringOctaves}u;
$_math''';

const _math = r'''
struct CloudMediaUniforms {v:array<vec4<f32>,25>};
@group(2) @binding(0) var<uniform> cloud:CloudMediaUniforms;
const CLOUD_INV_PI4:f32=.07957747154594767;
fn cloudRemap(x:f32,a:f32,b:f32)->f32{return clamp((x-a)/(b-a),0.,1.);}
fn cloudRemap4(x:vec4<f32>,a:vec4<f32>,b:vec4<f32>)->vec4<f32>{
 let diff=b-a;
 return clamp((x-a)/select(diff,vec4<f32>(1e-7),abs(diff)<vec4<f32>(1e-7)),vec4<f32>(0.),vec4<f32>(1.));
}
fn cloudGlobeUv(position:vec3<f32>)->vec2<f32>{
 let n=normalize(position);let f=abs(n);let c=n/max(f.x,max(f.y,f.z));var m:vec2<f32>;
 if(all(f.yy>f.xz)){m=select(n.xz,vec2<f32>(-n.x,n.z),c.y>0.);}
 else if(all(f.xx>f.yz)){m=select(vec2<f32>(-n.y,n.z),n.yz,c.x>0.);}
 else{m=select(vec2<f32>(n.x,-n.y),n.xy,c.z>0.);}
 let m2=m*m;let q=dot(m2,vec2<f32>(-2.,2.))-3.;
 let x=sqrt(max(0.,1.5+m2.x-m2.y-.5*sqrt(max(0.,-24.*m2.x+q*q))))*select(-1.,1.,m.x>0.);
 let y=sqrt(6./max(1e-7,3.-x*x))*m.y;return vec2<f32>(x,y)*.5+.5;
}
fn cloudInGap(height:f32)->bool{return any(vec3<f32>(height)>cloud.v[13].xyz & vec3<f32>(height)<cloud.v[14].xyz);}
struct CloudWeather {height:vec4<f32>,density:vec4<f32>};
fn cloudWeather(texel:vec4<f32>,height:f32,shadow:bool)->CloudWeather{
 let h=cloudRemap4(vec4<f32>(height),cloud.v[0],cloud.v[1]);
 var values=vec4<f32>(texel[u32(cloud.v[21].x)],texel[u32(cloud.v[21].y)],texel[u32(cloud.v[21].z)],texel[u32(cloud.v[21].w)]);
 values=pow(max(values,vec4<f32>(0.)),cloud.v[5]);
 if(shadow){values*=cloud.v[8];}
 let biased=pow(h,cloud.v[6]);let x=clamp(biased*2.-1.,vec4<f32>(-1.),vec4<f32>(1.));let heightScale=1.-x*x;
 let factor=1.-cloud.v[16].w*heightScale;
 let d=cloudRemap4(mix(values,vec4<f32>(1.),cloud.v[7]),factor,factor+cloud.v[7]);
 return CloudWeather(h,select(d,vec4<f32>(0.),cloud.v[1]<=cloud.v[0]));
}
struct CloudMedium {weight:vec4<f32>,scattering:f32,extinction:f32};
fn cloudMedium(weather:CloudWeather,shape:f32,detail:f32,mip:f32,jitter:f32)->CloudMedium{
 var density=cloudRemap4(weather.density,vec4<f32>(1.-shape)*cloud.v[3],vec4<f32>(1.));
 if(CLOUD_DETAIL && mip*.5+(jitter-.5)*.5<.5){
  let modifier=mix(vec4<f32>(pow(detail,6.)),vec4<f32>(1.-detail),cloudRemap4(weather.height,vec4<f32>(.2),vec4<f32>(.4)))*cloud.v[4];
  density=cloudRemap4(density*2.,modifier*.5,vec4<f32>(1.));
 }
 let profile=cloud.v[9]*exp(cloud.v[10]*weather.height)+cloud.v[11]*weather.height+cloud.v[12];
 density=clamp(density*cloud.v[2]*profile,vec4<f32>(0.),vec4<f32>(1.));
 let sum=dot(density,vec4<f32>(1.));let scattering=sum*cloud.v[17].w;
 return CloudMedium(density/max(sum,1e-20),scattering,sum*cloud.v[18].w+scattering);
}
fn cloudHG(g:vec2<f32>,cosTheta:f32)->vec2<f32>{
 let g2=g*g;return CLOUD_INV_PI4*(1.-g2)/max(vec2<f32>(1e-7),pow(1.+g2-2.*g*cosTheta,vec2<f32>(1.5)));
}
fn cloudPhase(cosTheta:f32,attenuation:f32)->f32{
 if(CLOUD_ACCURATE_PHASE){
  let g=.5556712547839497*attenuation;let a=21.995520856274638;let g2=g*g;
  let draine=(1.-g2)*(1.+a*cosTheta*cosTheta)/(4.*(1.+a*(1.+2.*g2)/3.)*3.141592653589793*pow(1.+g2-2.*g*cosTheta,1.5));
  return mix(cloudHG(vec2<f32>(.988176691700256*attenuation),cosTheta).x,draine,.4819554318404214);
 }
 return dot(cloudHG(cloud.v[24].xy*attenuation,cosTheta),vec2<f32>(1.-cloud.v[24].z,cloud.v[24].z));
}
fn cloudMultipleScattering(opticalDepth:f32,cosTheta:f32)->f32{
 var coeff=1.;var result=0.;for(var i=0u;i<CLOUD_OCTAVES;i++){
  result+=coeff*exp(-opticalDepth*coeff)*cloudPhase(cosTheta,coeff);coeff*=.5;
 }return result;
}
fn cloudStructureNormal(direction:vec3<f32>,jitter:f32)->vec3<f32>{
 let a=.85065080835204;let b=.5257311121191336;let k=.6180339887498948;let k2=.38196601125010515;
 let absD=abs(direction);let octant=sign(direction);
 var v1=select(vec3<f32>(-b,0.,a),vec3<f32>(a,b,0.),dot(absD,vec3<f32>(1.,k2,-k))>0.)*octant;
 var v2=select(vec3<f32>(a,-b,0.),vec3<f32>(0.,a,b),dot(absD,vec3<f32>(-k,1.,k2))>0.)*octant;
 var v3=select(vec3<f32>(0.,a,-b),vec3<f32>(b,0.,a),dot(absD,vec3<f32>(k2,-k,1.))>0.)*octant;
 let base=vec3<f32>(.5,.5,1.);
 if(dot(v1,base)>dot(v2,base)){let temp=v1;v1=v2;v2=temp;}
 if(dot(v2,base)>dot(v3,base)){let temp=v2;v2=v3;v3=temp;}
 if(dot(v1,base)>dot(v2,base)){let temp=v1;v1=v2;v2=temp;}
 let w=exp(vec3<f32>(dot(v1,direction),dot(v2,direction),dot(v3,direction))*40.);let weights=w/dot(w,vec3<f32>(1.));
 if(jitter<weights.x){return v1;}if(jitter<weights.x+weights.y){return v2;}return v3;
}
fn cloudStructuredPlanes(normal:vec3<f32>,origin:vec3<f32>,direction:vec3<f32>,period:f32)->vec2<f32>{
 let nd=dot(direction,normal);let step=period/max(abs(nd),1e-7);let distance=dot(origin,normal);
 var offset=-(distance-floor(distance/period)*period)/select(nd,1e-7,abs(nd)<1e-7);
 if(offset<0.){offset+=step;}return vec2<f32>(offset,step);
}
''';
