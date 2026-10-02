import 'quality.dart';

String cloudShadowMarchWgsl(CloudQuality q) =>
    '''
const CLOUD_SHADOW_ITERATIONS:u32=${q.shadow.maxIterationCount}u;
const CLOUD_SHADOW_MIN_STEP:f32=${q.shadow.minStepSize};
const CLOUD_SHADOW_MAX_STEP:f32=${q.shadow.maxStepSize};
const CLOUD_SHADOW_MIN_DENSITY:f32=${q.shadow.minDensity};
const CLOUD_SHADOW_MIN_EXTINCTION:f32=${q.shadow.minExtinction};
const CLOUD_SHADOW_MIN_TRANSMITTANCE:f32=${q.shadow.minTransmittance};
$_shadowMarch
''';
const _shadowMarch = r'''
fn cloudMarchShadow(origin:vec3<f32>,direction:vec3<f32>,distance:f32,jitter:f32,mip:f32)->vec4<f32>{
 let normal=cloudStructureNormal(direction,jitter);
 let planes=cloudStructuredPlanes(normal,origin,direction,clamp(distance/f32(CLOUD_SHADOW_ITERATIONS),CLOUD_SHADOW_MIN_STEP,CLOUD_SHADOW_MAX_STEP));
 let step=planes.y;var next=planes.x;
 var extinctionSum=0.;var optical=0.;var tail=0.;var transmittance=1.;var weighted=0.;var weight=0.;var count=0u;
 for(var i=0u;i<CLOUD_SHADOW_ITERATIONS;i++){
  if(next>distance){break;}
  let position=origin+next*direction;let height=length(position)-cf.camera.w;
  if(!cloudInGap(height)){
   let weather=cloudSampleWeather(position,height,mip,true);
   if(any(weather.density>vec4<f32>(CLOUD_SHADOW_MIN_DENSITY))){
    let medium=cloudSampleMedium(weather,position,mip,jitter);
    if(medium.extinction>CLOUD_SHADOW_MIN_EXTINCTION){
     extinctionSum+=medium.extinction;optical+=medium.extinction*step;transmittance*=exp(-medium.extinction*step);
     weighted+=next*transmittance;weight+=transmittance;count++;
    }
   }
  }
  if(transmittance<=CLOUD_SHADOW_MIN_TRANSMITTANCE){tail=min(2.*step*exp(1.-f32(count)),step*.5);break;}
  next+=step;
 }
 if(count==0u){return vec4<f32>(max(distance,0.),0.,0.,0.);}
 return vec4<f32>(min(weighted/max(weight,1e-30),distance),extinctionSum/f32(count),optical,tail);
}
''';

String cloudShadowComputeWgsl(int count) =>
    '''
@group(3) @binding(0) var shadowOutput:texture_storage_2d<rgba32float,write>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>){
 let size=textureDimensions(shadowOutput);if(any(id.xy>=size)){return;}
 let tileWidth=size.x/${count}u;let cascade=id.x/tileWidth;let pixel=vec2<u32>(id.x%tileWidth,id.y);
 let uv=(vec2<f32>(pixel)+.5)/vec2<f32>(vec2<u32>(tileWidth,size.y));
 let clip=vec4<f32>(uv.x*2.-1.,1.-uv.y*2.,-1.,1.);
 let world=cf.inverseShadows[cascade]*clip;let origin=cloudEcef(world.xyz/world.w);let direction=-cf.sun.xyz;
 let top=cloudSphere(origin,direction,cf.camera.w+cloud.v[20].w);
 let bottom=cloudSphere(origin,direction,cf.camera.w+cloud.v[20].z).x;
 var result=vec4<f32>(0.);
 if(top.y>=0. && cloud.v[20].w>cloud.v[20].z){
  let near=max(0.,top.x);let far=select(bottom,1e6,bottom<0.);
  let mips=array<f32,4>(0.,.5,1.,2.);
  result=cloudMarchShadow(origin+direction*near,direction,max(0.,far-near),cloudNoise(vec2<f32>(pixel),f32(size.y)),mips[cascade]);
 }
 textureStore(shadowOutput,vec2<i32>(id.xy),result);
}
''';

String cloudShadowSamplingWgsl(int count, {bool enabled = true}) => !enabled
    ? '''
fn cloudShadowDepth(position:vec3<f32>,offset:f32,radius:f32,jitter:f32)->f32{return 0.;}
'''
    : '''
const CLOUD_CASCADE_COUNT:i32=$count;
$_shadowSampling
''';
const _shadowSampling = r'''
@group(2) @binding(6) var cloudShadowAtlas:texture_2d<f32>;
fn cloudCascade(relative:vec3<f32>,jitter:f32)->i32{
 let depth=(dot(relative,cf.forward.xyz)-cf.shadowNearFar.x)/(cf.shadowNearFar.y-cf.shadowNearFar.x);
 var next=-1;var prev=-1;var alpha=0.;
 for(var i=0;i<CLOUD_CASCADE_COUNT;i++){
  var interval=cf.intervals[i].xy;let center=(interval.x+interval.y)*.5;
  let edge=select(interval.y,interval.x,depth<center);let margin=edge*edge*.5;interval+=margin*vec2<f32>(-.5,.5);
  if(depth>=interval.x && (i==CLOUD_CASCADE_COUNT-1 || depth<interval.y)){
   prev=next;next=i;
   var d=depth-interval.x;if(i<CLOUD_CASCADE_COUNT-1){d=min(d,interval.y-depth);}
   alpha=clamp(d/max(margin,1e-7),0.,1.);
  }
 }
 return select(prev,next,jitter<=alpha);
}
fn cloudShadowTexel(uv:vec2<f32>,cascade:i32)->vec4<f32>{
 let size=vec2<i32>(cf.shadowNearFar.zw);let p=uv*vec2<f32>(size)-.5;let i=vec2<i32>(floor(p));let f=fract(p);var result=vec4<f32>(0.);
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){
  let q=clamp(i+vec2<i32>(x,y),vec2<i32>(0),size-1)+vec2<i32>(cascade*size.x,0);
  result+=textureLoad(cloudShadowAtlas,q,0)*select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);
 }}return result;
}
fn cloudShadowOptical(uv:vec2<f32>,distance:f32,offset:f32,cascade:i32)->f32{
 let value=cloudShadowTexel(uv,cascade);return min(value.z+value.w,value.y*max(0.,distance-offset-value.x));
}
fn cloudShadowDepth(position:vec3<f32>,offset:f32,radius:f32,jitter:f32)->f32{
 let distance=cloudSphere(position,cf.sun.xyz,cf.camera.w+cloud.v[20].w).y;
 if(distance<=0. || cloud.v[20].w<=cloud.v[20].z){return 0.;}
 let relative=cloudWorld(position);let cascade=cloudCascade(relative,jitter);if(cascade<0){return 0.;}
 let clip=cf.shadowMatrices[cascade]*vec4<f32>(relative,1.);let ndc=clip.xy/clip.w;let uv=vec2<f32>(ndc.x*.5+.5,.5-ndc.y*.5);
 if(any(uv<vec2<f32>(0.))||any(uv>vec2<f32>(1.))){return 0.;}
 if(radius<.1){return cloudShadowOptical(uv,distance,offset,cascade);}
 var sum=0.;for(var i=0u;i<8u;i++){
  let r=sqrt((f32(i)+.5)/8.);let angle=f32(i)*2.399963229728653+jitter*6.283185307179586;
  let delta=r*vec2<f32>(cos(angle),sin(angle))*radius/cf.shadowNearFar.zw;
  sum+=cloudShadowOptical(uv+delta,distance,offset,cascade);
 }return sum/8.;
}
''';
