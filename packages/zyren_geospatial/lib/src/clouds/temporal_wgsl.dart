const cloudVarianceWgsl = r'''
fn cloudVariance(history:vec4<f32>,moment1:vec4<f32>,moment2:vec4<f32>,count:f32,gamma:f32)->vec4<f32>{
 let mean=moment1/count;let sigma=sqrt(max(moment2/count-mean*mean,vec4<f32>(0.)))*gamma;
 let lower=mean-sigma;let upper=mean+sigma;
 let center=.5*(upper.rgb+lower.rgb);let extent=.5*(upper.rgb-lower.rgb)+vec3<f32>(1e-7);
 let delta=history-vec4<f32>(center,mean.a);let unit=abs(delta.rgb/extent);let maximum=max(unit.x,max(unit.y,unit.z));
 if(maximum>1.){return vec4<f32>(center,mean.a)+delta/maximum;}return history;
}
''';
const cloudTemporalUniformWgsl = r'''
struct CloudTemporal {size:vec4<f32>,state:vec4<f32>,jitter:vec4<f32>};
@group(2) @binding(8) var<uniform> ct:CloudTemporal;
''';
const cloudResolveWgsl = r'''
@group(1) @binding(0) var currentColor:texture_2d<f32>;
@group(1) @binding(1) var currentData:texture_2d<f32>;
@group(1) @binding(2) var previousColor:texture_2d<f32>;
@group(1) @binding(3) var previousData:texture_2d<f32>;
@group(3) @binding(0) var resolvedColor:texture_storage_2d<rgba16float,write>;
@group(3) @binding(1) var resolvedData:texture_storage_2d<rgba32float,write>;
fn cloudBilinear(map:texture_2d<f32>,uv:vec2<f32>)->vec4<f32>{
 let size=vec2<i32>(textureDimensions(map));let p=uv*vec2<f32>(size)-.5;let base=vec2<i32>(floor(p));let f=fract(p);var value=vec4<f32>(0.);
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){value+=textureLoad(map,clamp(base+vec2<i32>(x,y),vec2<i32>(0),size-1),0)*select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);}}
 return value;
}
fn cloudClosest(coord:vec2<i32>)->vec4<f32>{
 let size=vec2<i32>(textureDimensions(currentData));var result=vec4<f32>(1e30,0.,0.,0.);
 for(var y=-1;y<=1;y++){for(var x=-1;x<=1;x++){
  let value=textureLoad(currentData,clamp(coord+vec2<i32>(x,y),vec2<i32>(0),size-1),0);if(value.x<result.x){result=value;}
 }}return result;
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let pixel=vec2<i32>(v.position.xy);let original=textureLoad(sceneColor,pixel,0);if(any(pixel>=vec2<i32>(ct.size.xy))){return original;}
 let upscale=ct.jitter.z>1.5;let mode=ct.jitter.z;let uv=(vec2<f32>(pixel)+.5)/ct.size.xy;
 let rawSize=vec2<i32>(ct.size.zw);let coord=clamp(select(pixel,pixel/4,upscale),vec2<i32>(0),rawSize-1);
 let current=textureLoad(currentColor,coord,0);let data=textureLoad(currentData,coord,0);let closest=cloudClosest(coord);
 let prevUv=uv-closest.yz;var color=current;var shadow=data.w;
 let bayer=array<i32,16>(0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5);
 let currentFrame=upscale&&bayer[(pixel.y%4)*4+pixel.x%4]==i32(ct.state.y);
 var accepted=ct.state.x>.5&&mode>.5&&!currentFrame&&all(prevUv>=vec2<f32>(0.))&&all(prevUv<=vec2<f32>(1.));
 if(accepted){
  let previous=cloudBilinear(previousData,prevUv);
  accepted=abs(previous.x-data.x)<=max(100.,data.x*.05);
 }
 if(accepted){
  let history=cloudBilinear(previousColor,prevUv);let oldShadow=cloudBilinear(previousData,prevUv).w;
  var first=current;var second=current*current;var shadowFirst=vec4<f32>(vec3<f32>(shadow),1.);var shadowSecond=shadowFirst*shadowFirst;
  let offsets=array<vec2<i32>,4>(vec2<i32>(1,0),vec2<i32>(0,-1),vec2<i32>(0,1),vec2<i32>(-1,0));
  for(var i=0;i<4;i++){
   var c:vec4<f32>;var s:f32;
   if(upscale){let next=uv+vec2<f32>(offsets[i])/ct.size.zw;c=cloudBilinear(currentColor,next);s=cloudBilinear(currentData,next).w;}
   else{let next=clamp(coord+offsets[i],vec2<i32>(0),rawSize-1);c=textureLoad(currentColor,next,0);s=textureLoad(currentData,next,0).w;}
   first+=c;second+=c*c;let sv=vec4<f32>(vec3<f32>(s),1.);shadowFirst+=sv;shadowSecond+=sv*sv;
  }
  let gamma=select(1.,ct.state.w,upscale);let clipped=cloudVariance(history,first,second,5.,gamma);let clippedShadow=cloudVariance(vec4<f32>(vec3<f32>(oldShadow),1.),shadowFirst,shadowSecond,5.,gamma).x;
  color=mix(clipped,current,select(ct.state.z,0.,upscale));shadow=mix(clippedShadow,shadow,select(ct.state.z,0.,upscale));
 }
 textureStore(resolvedColor,pixel,vec4<f32>(max(color.rgb,vec3<f32>(0.)),clamp(color.a,0.,1.)));
 textureStore(resolvedData,pixel,vec4<f32>(data.xyz,max(shadow,0.)));return original;
}
''';
const cloudPublishWgsl = r'''
@group(1) @binding(0) var resolvedColor:texture_2d<f32>;
@group(1) @binding(1) var resolvedData:texture_2d<f32>;
@group(1) @binding(2) var transmission:texture_2d<f32>;
@group(3) @binding(0) var publishedColor:texture_storage_2d<rgba16float,write>;
@group(3) @binding(1) var publishedData:texture_storage_2d<rgba32float,write>;
@group(3) @binding(2) var publishedTransmission:texture_storage_2d<r32float,write>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let pixel=vec2<i32>(v.position.xy);let original=textureLoad(sceneColor,pixel,0);let size=textureDimensions(publishedColor);if(any(pixel>=vec2<i32>(size))){return original;}
 textureStore(publishedColor,pixel,textureLoad(resolvedColor,pixel,0));textureStore(publishedData,pixel,textureLoad(resolvedData,pixel,0));
 let coord=min(vec2<i32>((vec2<f32>(pixel)+.5)/vec2<f32>(size)*vec2<f32>(textureDimensions(transmission))),vec2<i32>(textureDimensions(transmission))-1);
 textureStore(publishedTransmission,pixel,textureLoad(transmission,coord,0));return original;
}
''';
