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
// Direct texture references avoid the Pixel Mali compiler's image-argument crash.
final cloudResolveWgsl =
    r'''
@group(1) @binding(0) var currentColor:texture_2d<f32>;
@group(1) @binding(1) var currentData:texture_2d<f32>;
@group(1) @binding(2) var previousColor:texture_2d<f32>;
@group(1) @binding(3) var previousData:texture_2d<f32>;
@group(1) @binding(4) var currentTransmission:texture_2d<f32>;
@group(3) @binding(1) var resolvedData:texture_storage_2d<rgba32float,write>;
''' +
    [
      for (final name in [
        'currentColor',
        'currentData',
        'previousColor',
        'previousData',
      ])
        '''
fn cloudBilinear_$name(uv:vec2<f32>)->vec4<f32>{
 let size=${name.startsWith('current') ? 'vec2<i32>(ct.size.zw)' : 'vec2<i32>(textureDimensions($name))'};let p=uv*vec2<f32>(size)-.5;let base=vec2<i32>(floor(p));let f=fract(p);var value=vec4<f32>(0.);
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){value+=textureLoad($name,clamp(base+vec2<i32>(x,y),vec2<i32>(0),size-1),0)*select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);}}
 return value;
}
''',
    ].join() +
    r'''
struct CloudSpatial {color:vec4<f32>,data:vec4<f32>,transmission:f32};
fn cloudSpatial(pixel:vec2<i32>,reference:vec4<f32>)->CloudSpatial{
 let size=vec2<i32>(ct.size.zw);
 let p=(vec2<f32>(pixel)-ct.jitter.xy)/ct.jitter.w;let base=vec2<i32>(floor(p));let f=fract(p);
 var color=vec4<f32>(0.);var data=vec4<f32>(0.);var transmission=0.;var total=0.;
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){
  let coord=clamp(base+vec2<i32>(x,y),vec2<i32>(0),size-1);
  let d=textureLoad(currentData,coord,0);
  let weight=select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);
  // Keep opaque foreground and distant cloud rays on their own side of an edge.
  if(abs(d.x-reference.x)<=max(100.,reference.x*.2)){
   color+=textureLoad(currentColor,coord,0)*weight;data+=d*weight;
   transmission+=textureLoad(currentTransmission,coord,0).r*weight;total+=weight;
  }
 }}
 let coord=clamp(vec2<i32>(round(p)),vec2<i32>(0),size-1);
 if(total<1e-6){return CloudSpatial(textureLoad(currentColor,coord,0),reference,textureLoad(currentTransmission,coord,0).r);}
 return CloudSpatial(color/total,data/total,transmission/total);
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let pixel=vec2<i32>(v.position.xy);
 let upscale=ct.jitter.z>1.5;let mode=ct.jitter.z;let uv=(vec2<f32>(pixel)+.5)/ct.size.xy;
 let rawSize=vec2<i32>(ct.size.zw);let coord=clamp(select(pixel,pixel/i32(ct.jitter.w),upscale),vec2<i32>(0),rawSize-1);
 var current=textureLoad(currentColor,coord,0);var data=textureLoad(currentData,coord,0);
 var transmission=textureLoad(currentTransmission,coord,0).r;
 let nearest=clamp(vec2<i32>(round((vec2<f32>(pixel)-ct.jitter.xy)/ct.jitter.w)),vec2<i32>(0),rawSize-1);
 if(upscale){let spatial=cloudSpatial(pixel,textureLoad(currentData,nearest,0));current=spatial.color;data=spatial.data;transmission=spatial.transmission;}
 let prevUv=uv-data.yz;var color=current;var shadow=data.w;
 let currentFrame=upscale&&all(vec2<f32>(pixel%vec2<i32>(i32(ct.jitter.w)))==ct.jitter.xy);
 var accepted=ct.state.x>.5&&mode>.5&&!currentFrame&&all(prevUv>=vec2<f32>(0.))&&all(prevUv<=vec2<f32>(1.));
 // Phase rays can cross cloud depth gradients. Reject large depth changes,
 // while the narrower spatial filter keeps new silhouettes out of sky pixels.
 if(accepted){
  let previous=cloudBilinear_previousData(prevUv);
  let tolerance=select(max(100.,data.x*.05),max(100.,min(previous.x,data.x)),upscale);
  accepted=abs(previous.x-data.x)<=tolerance;
 }
 if(currentFrame){color=textureLoad(currentColor,coord,0);shadow=textureLoad(currentData,coord,0).w;transmission=textureLoad(currentTransmission,coord,0).r;data=textureLoad(currentData,coord,0);}
 if(accepted){
  let history=cloudBilinear_previousColor(prevUv);let oldShadow=cloudBilinear_previousData(prevUv).w;
  let oldTransmission=cloudBilinear_previousData(prevUv).y;
  let center=textureLoad(currentColor,coord,0);
  var first=center;var second=center*center;var shadowFirst=vec4<f32>(vec3<f32>(shadow),1.);var shadowSecond=shadowFirst*shadowFirst;
  var transmissionFirst=vec4<f32>(vec3<f32>(transmission),1.);var transmissionSecond=transmissionFirst*transmissionFirst;
  let offsets=array<vec2<i32>,4>(vec2<i32>(1,0),vec2<i32>(0,-1),vec2<i32>(0,1),vec2<i32>(-1,0));
  for(var i=0;i<4;i++){
   var c:vec4<f32>;var s:f32;
   if(upscale){let next=uv+vec2<f32>(offsets[i])/ct.size.zw;c=cloudBilinear_currentColor(next);s=cloudBilinear_currentData(next).w;}
   else{let next=clamp(coord+offsets[i],vec2<i32>(0),rawSize-1);c=textureLoad(currentColor,next,0);s=textureLoad(currentData,next,0).w;}
   let next=clamp(coord+offsets[i],vec2<i32>(0),rawSize-1);
   let tv=vec4<f32>(vec3<f32>(textureLoad(currentTransmission,next,0).r),1.);transmissionFirst+=tv;transmissionSecond+=tv*tv;
   first+=c;second+=c*c;let sv=vec4<f32>(vec3<f32>(s),1.);shadowFirst+=sv;shadowSecond+=sv*sv;
  }
  let gamma=select(1.,ct.state.w,upscale);let clipped=cloudVariance(history,first,second,5.,gamma);let clippedShadow=cloudVariance(vec4<f32>(vec3<f32>(oldShadow),1.),shadowFirst,shadowSecond,5.,gamma).x;
  color=mix(clipped,current,select(ct.state.z,0.,upscale));shadow=mix(clippedShadow,shadow,select(ct.state.z,0.,upscale));
  let clippedTransmission=cloudVariance(vec4<f32>(vec3<f32>(oldTransmission),1.),transmissionFirst,transmissionSecond,5.,gamma).x;
  transmission=mix(clippedTransmission,transmission,select(ct.state.z,0.,upscale));
 }
 // History only needs depth and shadow length. Its Y channel carries resolved
 // ground transmission; publication restores the current ray's UV velocity.
 textureStore(resolvedData,pixel,vec4<f32>(data.x,clamp(transmission,0.,1.),0.,max(shadow,0.)));
 return vec4<f32>(max(color.rgb,vec3<f32>(0.)),clamp(color.a,0.,1.));
}
''';
const cloudPublishWgsl = r'''
@group(1) @binding(0) var resolvedColor:texture_2d<f32>;
@group(1) @binding(1) var resolvedData:texture_2d<f32>;
@group(1) @binding(2) var currentData:texture_2d<f32>;
@group(3) @binding(1) var publishedData:texture_storage_2d<rgba32float,write>;
@group(3) @binding(2) var publishedTransmission:texture_storage_2d<r32float,write>;
@group(3) @binding(3) var historyData:texture_storage_2d<rgba32float,write>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let pixel=vec2<i32>(v.position.xy);
 let resolved=textureLoad(resolvedData,pixel,0);
 textureStore(historyData,pixel,resolved);
 let coord=clamp(select(pixel,pixel/i32(ct.jitter.w),ct.jitter.z>1.5),vec2<i32>(0),vec2<i32>(textureDimensions(currentData))-1);
 let motion=textureLoad(currentData,coord,0).yz;
 textureStore(publishedData,pixel,vec4<f32>(resolved.x,motion,resolved.w));
 textureStore(publishedTransmission,pixel,vec4<f32>(resolved.y,0.,0.,0.));return textureLoad(resolvedColor,pixel,0);
}
''';
