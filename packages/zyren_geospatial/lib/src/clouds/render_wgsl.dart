import 'quality.dart';

String cloudRenderWgsl(CloudQuality q) =>
    '''
const CLOUD_ACCURATE_LIGHT:bool=${q.clouds.accurateSunSkyLight};
const CLOUD_HAZE:bool=${q.haze};
const CLOUD_SHAFTS:bool=${q.lightShafts};
const CLOUD_ITERATIONS:u32=${q.clouds.maxIterationCount}u;
const CLOUD_MIN_STEP:f32=${q.clouds.minStepSize};
const CLOUD_MAX_STEP:f32=${q.clouds.maxStepSize};
const CLOUD_MAX_DISTANCE:f32=${q.clouds.maxRayDistance};
const CLOUD_STEP_SCALE:f32=${q.clouds.perspectiveStepScale};
const CLOUD_MIN_DENSITY:f32=${q.clouds.minDensity};
const CLOUD_MIN_EXTINCTION:f32=${q.clouds.minExtinction};
const CLOUD_MIN_TRANSMITTANCE:f32=${q.clouds.minTransmittance};
const CLOUD_SUN_ITERATIONS:u32=${q.clouds.maxIterationCountToSun}u;
const CLOUD_GROUND_ITERATIONS:u32=${q.clouds.maxIterationCountToGround}u;
const CLOUD_SECONDARY_STEP:f32=${q.clouds.minSecondaryStepSize};
const CLOUD_SECONDARY_SCALE:f32=${q.clouds.secondaryStepScale};
const CLOUD_SHAFT_ITERATIONS:u32=${q.clouds.maxShadowLengthIterationCount}u;
const CLOUD_SHAFT_STEP:f32=${q.clouds.minShadowLengthStepSize};
const CLOUD_SHAFT_DISTANCE:f32=${q.clouds.maxShadowLengthRayDistance};
$_render
''';
const _render = r'''
struct CloudLight {sun:vec3<f32>,sky:vec3<f32>};
fn cloudScalarLight(position:vec3<f32>)->CloudLight{
 let p=position*.001;
 return CloudLight(atmosphereSunIrradiance(p,cf.sun.xyz,cf.sun.xyz),atmosphereSkyIrradiance(p,normalize(p),cf.sun.xyz)*(2.*PI));
}
fn cloudLight(position:vec3<f32>,height:f32)->CloudLight{
 if(CLOUD_ACCURATE_LIGHT){return cloudScalarLight(position);}
 let radial=normalize(cf.camera.xyz);let low=cloudScalarLight(radial*(cf.camera.w+cloud.v[13].w));let high=cloudScalarLight(radial*(cf.camera.w+cloud.v[14].w));
 let alpha=cloudRemap(height,cloud.v[13].w,max(cloud.v[13].w+1e-6,cloud.v[14].w));
 return CloudLight(mix(low.sun,high.sun,alpha),mix(low.sky,high.sky,alpha));
}
fn cloudOpticalDepth(origin:vec3<f32>,direction:vec3<f32>,maximum:u32,mip:f32,jitter:f32)->vec2<f32>{
 let count=u32(max(0.,mix(f32(maximum+1u),1.,mip)-jitter));
 if(count==0u){return vec2<f32>(.5,0.);}
 var step=CLOUD_SECONDARY_STEP/f32(count);var next=step*jitter;var depth=0.;var distance=0.;
 for(var i=0u;i<count;i++){
  distance=next;let position=origin+direction*distance;let weather=cloudSampleWeather(position,length(position)-cf.camera.w,mip,false);
  depth+=cloudSampleMedium(weather,position,mip,jitter).extinction*step;next+=step;step*=CLOUD_SECONDARY_SCALE;
 }return vec2<f32>(depth,distance);
}
fn cloudGroundBounce(position:vec3<f32>,normal:vec3<f32>,height:f32,mip:f32,jitter:f32)->vec3<f32>{
 let optical=cloudOpticalDepth(position,-normal,CLOUD_GROUND_ITERATIONS,mip,jitter).x;
 var light=cloudScalarLight(cf.camera.xyz);
 if(CLOUD_ACCURATE_LIGHT){
  let p=(position-normal*height)*.001;
  light=CloudLight(atmosphereSunIrradiance(p,normal,cf.sun.xyz),atmosphereSkyIrradiance(p,normal,cf.sun.xyz));
 }
 return .3/PI*(light.sky+(1.-cloud.v[16].w)*light.sun)*exp(-optical);
}
struct CloudMarch {color:vec4<f32>,depth:f32};
fn cloudMarch(origin:vec3<f32>,direction:vec3<f32>,range:vec2<f32>,cosTheta:f32,jitter:f32,startTexels:f32)->CloudMarch{
 var radiance=vec3<f32>(0.);var transmission=1.;var weighted=0.;var weight=0.;var first=-1.;
 let distance=range.y-range.x;var step=CLOUD_MIN_STEP+(CLOUD_STEP_SCALE-1.)*range.x;
 // Perspective growth can exceed an entire layer from orbit. Keep distant
 // samples within a quarter of the thinnest active layer along this ray.
 var thickness=CLOUD_MAX_STEP*4.;
 for(var layer=0u;layer<4u;layer++){
  let height=cloud.v[1][layer]-cloud.v[0][layer];
  if(height>0. && cloud.v[2][layer]>0.){thickness=min(thickness,height);}
 }
 let radial=max(abs(dot(normalize(origin),direction)),.05);
 let limit=max(CLOUD_MIN_STEP,min(CLOUD_MAX_STEP,thickness*.25/radial));
 let distant=step>limit;step=select(step,limit,distant);var next=step*jitter*2.;
 for(var i=0u;i<CLOUD_ITERATIONS;i++){
  if(next>distance){break;}
  let p=origin+direction*next;let height=length(p)-cf.camera.w;let mip=log2(max(1.,startTexels+next*1e-5));
  if(cloudInGap(height)){step=select(step*CLOUD_STEP_SCALE,min(step*CLOUD_STEP_SCALE,limit),distant);let advance=mix(step,CLOUD_MAX_STEP,min(1.,mip));next+=select(advance,min(advance,limit),distant);continue;}
  let weather=cloudSampleWeather(p,height,mip,false);
  if(!any(weather.density>vec4<f32>(CLOUD_MIN_DENSITY))){step=select(step*CLOUD_STEP_SCALE,min(step*CLOUD_STEP_SCALE,limit),distant);let advance=mix(step,CLOUD_MAX_STEP,min(1.,mip));next+=select(advance,min(advance,limit),distant);continue;}
  let medium=cloudSampleMedium(weather,p,mip,jitter);
  if(medium.extinction>CLOUD_MIN_EXTINCTION){
   let light=cloudLight(p,height);let normal=normalize(p);let secondary=cloudOpticalDepth(p,cf.sun.xyz,CLOUD_SUN_ITERATIONS,mip,jitter);
   var optical=secondary.x;
   if(height<cloud.v[20].w){optical+=cloudShadowDepth(p,secondary.y,cloud.v[24].w*cloudRemap(dot(cf.sun.xyz,normal),.1,0.),jitter);}
   var scattered=light.sun*cloudMultipleScattering(optical,cosTheta);
   if(CLOUD_GROUND_ITERATIONS>0u && cloud.v[22].y>0. && height<cloud.v[20].w && mip<.5){scattered+=cloudGroundBounce(p,normal,height,mip,jitter)*CLOUD_INV_PI4*cloud.v[22].y;}
   let gradient=dot(weather.height*.5+.5,medium.weight);
   scattered+=light.sky*CLOUD_INV_PI4*gradient*cloud.v[22].x;scattered*=medium.scattering;
   scattered*=1.-cloud.v[22].z*exp(-medium.extinction*cloud.v[22].w);
   let tr=exp(-medium.extinction*step);let integral=(scattered-scattered*tr)/max(medium.extinction,1e-7);
   radiance+=transmission*integral;transmission*=tr;
   if(first<0.){first=next;}weighted+=next*transmission;weight+=transmission;
  }
  if(transmission<=CLOUD_MIN_TRANSMITTANCE){break;}step=select(step*CLOUD_STEP_SCALE,min(step*CLOUD_STEP_SCALE,limit),distant);next+=step;
 }
 var depth=first;if(weight>0.){depth=weighted/weight;}
 return CloudMarch(vec4<f32>(radiance,cloudRemap(transmission,1.,CLOUD_MIN_TRANSMITTANCE)),depth);
}
fn cloudShadowLength(origin:vec3<f32>,direction:vec3<f32>,range:vec2<f32>,jitter:f32)->f32{
 if(!CLOUD_SHAFTS || cloud.v[20].w<=cloud.v[20].z || range.y<range.x || range.x<0.){return 0.;}
 var result=0.;var step=CLOUD_SHAFT_STEP;var next=step*jitter;
 for(var i=0u;i<CLOUD_SHAFT_ITERATIONS;i++){
  if(next>range.y-range.x){break;}
  result+=(1.-exp(-cloudShadowDepth(origin+direction*next,0.,0.,jitter)))*step;
  step*=CLOUD_STEP_SCALE;next+=step;
 }return result;
}
fn cloudHaze(origin:vec3<f32>,direction:vec3<f32>,distance:f32,cosTheta:f32,shadowLength:f32)->vec4<f32>{
 if(!CLOUD_HAZE || distance<=0.){return vec4<f32>(0.);}
 let height=length(cf.camera.xyz)-cf.camera.w;let modulation=cloudRemap(cloud.v[16].w,.2,.4);
 if(height*modulation<0.){return vec4<f32>(0.);}
 let density=modulation*cloud.v[23].x*exp(-height*cloud.v[23].y);if(density<1e-7){return vec4<f32>(0.);}
 let n=normalize(origin);let horizon=(origin-dot(origin,direction)*direction)/cf.camera.w;
 let normal=mix(n,horizon,cloudRemap(dot(n,horizon),.9,1.));let angle=max(dot(normal,direction),1e-5);
 let exponent=angle*cloud.v[23].y;let linear=density/cloud.v[23].y/angle;
 let expTerm=1.-exp(-distance*exponent);let shadowTerm=1.-exp(-min(distance,shadowLength)*exponent);
 let tr=clamp(1.-exp(-expTerm*linear),0.,1.);let shadowTr=clamp(1.-exp(-max((expTerm-shadowTerm)*linear,0.)),0.,1.);
 let light=cloudScalarLight(cf.camera.xyz);
 var color=light.sun*cloudPhase(cosTheta,1.)*shadowTr+light.sky*CLOUD_INV_PI4*cloud.v[22].x*tr;
 color*=cloud.v[23].z/max(cloud.v[23].z+cloud.v[23].w,1e-20);return vec4<f32>(color,tr);
}
struct CloudRanges {clouds:vec2<f32>,shadow:vec2<f32>,haze:vec2<f32>,ground:f32};
fn cloudRanges(origin:vec3<f32>,direction:vec3<f32>)->CloudRanges{
 let h=length(origin)-cf.camera.w;let ground=cloudSphere(origin,direction,cf.camera.w);
 let low=cloudSphere(origin,direction,cf.camera.w+cloud.v[13].w);let high=cloudSphere(origin,direction,cf.camera.w+cloud.v[14].w);
 let shadow=cloudSphere(origin,direction,cf.camera.w+cloud.v[20].w);let hitsGround=ground.x>=0.;
 var ranges=CloudRanges(vec2<f32>(-1.),vec2<f32>(-1.),vec2<f32>(-1.),ground.x);
 if(cloud.v[14].w>cloud.v[13].w){
  if(h<cloud.v[13].w){if(!hitsGround){ranges.clouds=vec2<f32>(low.y,min(high.y,CLOUD_MAX_DISTANCE));}}
  else if(h<cloud.v[14].w){ranges.clouds=vec2<f32>(cf.sun.w,select(high.y,low.x,hitsGround));}
  else{ranges.clouds=vec2<f32>(high.x,select(high.y,low.x,hitsGround));}
 }
 if(h<cloud.v[20].w){ranges.shadow=vec2<f32>(cf.sun.w,select(shadow.y,ground.x,hitsGround));}
 else{ranges.shadow=vec2<f32>(shadow.x,select(shadow.y,ground.x,hitsGround));}
 ranges.shadow.y=min(ranges.shadow.y,CLOUD_SHAFT_DISTANCE);
 ranges.haze=vec2<f32>(cf.sun.w,select(high.y,ground.x,hitsGround));
 return ranges;
}
@group(3) @binding(0) var cloudColorOutput:texture_storage_2d<rgba16float,write>;
@group(3) @binding(1) var cloudDataOutput:texture_storage_2d<rgba32float,write>;
@group(3) @binding(2) var cloudTransmissionOutput:texture_storage_2d<r32float,write>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let pixel=vec2<i32>(v.position.xy);let original=textureLoad(sceneColor,pixel,0);
 let samplePixel=select(vec2<f32>(pixel),min(vec2<f32>(pixel)*4.+ct.jitter.xy,ct.size.xy-1.),ct.jitter.z>1.5);
 let uv=(samplePixel+.5)/cf.extent.xy;let middle=scenePosition(uv,.5);
 var worldRay=normalize(middle);var relativeOrigin=vec3<f32>(0.);
 if(cf.forward.w>0.){worldRay=cf.forward.xyz;relativeOrigin=scenePosition(uv,sceneNearDepth())-worldRay*cf.sun.w;}
 let origin=cloudEcef(relativeOrigin);let ray=normalize((cf.worldToEcef*vec4<f32>(worldRay,0.)).xyz);
 var ranges=cloudRanges(origin,ray);
 let globeUv=cloudGlobeUv(origin+ray*max(ranges.clouds.x,0.))*cloud.v[15].xy;
 let coord=globeUv*cf.extent.xy*select(1.,.25,ct.jitter.z>1.5);let dx=dpdx(coord);let dy=dpdy(coord);
 let mip=max(0.,.5*log2(max(1.,max(dot(dx,dx),dot(dy,dy))*.1)))*clamp(.2*(length(origin)-cf.camera.w)/max(cloud.v[14].w,1.),0.,1.);
 // Derivatives execute before the producer's bounded target branch.
 if(any(pixel>=vec2<i32>(ct.size.zw))){return original;}
 let depthPixel=clamp(vec2<i32>(uv*vec2<f32>(textureDimensions(sceneDepth))),vec2<i32>(0),vec2<i32>(textureDimensions(sceneDepth))-1);
 let depth=textureLoad(sceneDepth,depthPixel,0);let background=sceneDepthIsBackground(depth);
 var sceneDistance=cf.extent.z;var scenePoint=origin+ray*sceneDistance;
 if(!background){
  let relative=scenePosition(uv,depth);scenePoint=cloudEcef(relative);sceneDistance=max(0.,dot(relative-relativeOrigin,worldRay));
  ranges.clouds.y=min(ranges.clouds.y,sceneDistance);ranges.shadow.y=min(ranges.shadow.y,sceneDistance);ranges.haze.y=min(ranges.haze.y,sceneDistance);
 }else if(ranges.ground>=0.){scenePoint=origin+ray*ranges.ground;}
 let jitter=cloudNoise(vec2<f32>(pixel),ct.size.w);let cosTheta=dot(cf.sun.xyz,ray);
 var color=vec4<f32>(0.);var front=sceneDistance;var hit=false;
 if(all(ranges.clouds>=vec2<f32>(0.))&&ranges.clouds.y>=ranges.clouds.x){
  let marched=cloudMarch(origin+ray*ranges.clouds.x,ray,ranges.clouds,cosTheta,jitter,exp2(mip));color=marched.color;
  if(marched.depth>=0.){
   hit=true;front=ranges.clouds.x+marched.depth;
   ranges.shadow.y=mix(ranges.shadow.y,min(front,ranges.shadow.y),color.a);
   ranges.haze.y=mix(ranges.haze.y,min(front,ranges.haze.y),color.a);
  }
 }
 let shadowLength=cloudShadowLength(origin+ray*ranges.shadow.x,ray,ranges.shadow,jitter);
 if(hit){
  let air=atmosphereSegmentShadow(origin*.001,(origin+ray*front)*.001,cf.sun.xyz,shadowLength*.001);
  color=vec4<f32>(color.rgb*air.transmittance+air.radiance*color.a,color.a);
 }
 let haze=cloudHaze(origin+ray*cf.sun.w,ray,ranges.haze.y-ranges.haze.x,cosTheta,shadowLength);
 color=vec4<f32>(mix(color.rgb,haze.rgb,haze.a),color.a*(1.-haze.a)+haze.a);
 let relative=relativeOrigin+worldRay*front;let previous=cf.previousViewProjection*vec4<f32>(relative+cf.previousCamera.xyz,1.);
 var velocity=vec2<f32>(0.);if(cf.previousCamera.w>0.&&previous.w>0.){velocity=uv-vec2<f32>(previous.x/previous.w*.5+.5,.5-previous.y/previous.w*.5);}
 var transmission=1.;if(!background||ranges.ground>=0.){transmission=exp(-cloudShadowDepth(scenePoint,0.,cloud.v[24].w,jitter));}
 textureStore(cloudColorOutput,pixel,vec4<f32>(clamp(color.rgb,vec3<f32>(0.),vec3<f32>(65504.)),clamp(color.a,0.,1.)));
 textureStore(cloudDataOutput,pixel,vec4<f32>(front,velocity,shadowLength*.001));
 textureStore(cloudTransmissionOutput,pixel,vec4<f32>(transmission,0.,0.,1.));
 return original;
}
''';
