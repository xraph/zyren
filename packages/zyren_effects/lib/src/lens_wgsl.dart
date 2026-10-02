import 'package:zyren/zyren.dart';

String lensKawaseWgsl(int kernel) =>
    '''
${PostProcessDescriptor.interfaceWgsl}
$lensUniformWgsl
@group(1) @binding(0) var inputImage:texture_2d<f32>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let uv=vec2<f32>(v.uv.x,1.-v.uv.y);let d=${kernel + .5}/lens.render.zw;
 return (sampleGl(inputImage,uv+d)+sampleGl(inputImage,uv-d)+sampleGl(inputImage,uv+vec2<f32>(d.x,-d.y))+sampleGl(inputImage,uv+vec2<f32>(-d.x,d.y)))*.25;
}
''';

const lensCopyWgsl =
    '''
${PostProcessDescriptor.interfaceWgsl}
$lensUniformWgsl
@group(1) @binding(0) var inputImage:texture_2d<f32>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 return sampleGl(inputImage,vec2<f32>(v.uv.x,1.-v.uv.y));
}
''';

const lensCompositeWgsl =
    '''
${PostProcessDescriptor.interfaceWgsl}
$lensUniformWgsl
@group(1) @binding(0) var bloomImage:texture_2d<f32>;
@group(1) @binding(1) var featureImage:texture_2d<f32>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let color=textureLoad(sceneColor,vec2<i32>(v.position.xy),0);
 let uv=vec2<f32>(v.uv.x,1.-v.uv.y);
 return vec4<f32>(color.rgb+(sampleGl(bloomImage,uv).rgb+sampleGl(featureImage,uv).rgb)*lens.render.y,color.a);
}
''';

const lensUniformWgsl = '''
struct LensSettings { threshold:vec4<f32>, render:vec4<f32> };
@group(2) @binding(0) var<uniform> lens:LensSettings;
fn sampleGl(image:texture_2d<f32>,uv:vec2<f32>)->vec4<f32>{
 let size=vec2<i32>(textureDimensions(image));
 let p=vec2<f32>(uv.x,1.-uv.y)*vec2<f32>(size)-.5;
 let b=vec2<i32>(floor(p));let f=fract(p);
 let a=textureLoad(image,clamp(b,vec2<i32>(0),size-1),0);
 let c=textureLoad(image,clamp(b+vec2<i32>(1,0),vec2<i32>(0),size-1),0);
 let d=textureLoad(image,clamp(b+vec2<i32>(0,1),vec2<i32>(0),size-1),0);
 let e=textureLoad(image,clamp(b+vec2<i32>(1),vec2<i32>(0),size-1),0);
 return mix(mix(a,c,f.x),mix(d,e,f.x),f.y);
}
fn borderWeight(uv:vec2<f32>)->f32 {return select(0.,1.,all(uv>=vec2<f32>(0.))&&all(uv<=vec2<f32>(1.)));}
''';

const lensThresholdWgsl =
    '''
${PostProcessDescriptor.interfaceWgsl}
$lensUniformWgsl
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let uv=vec2<f32>(v.uv.x,1.-v.uv.y);let d=1./lens.render.zw;
 // Preserve the source vertex shader's shifted center and edge masks.
 var color=sampleGl(sceneColor,uv+d).rgb*.125;
 let inner=array<vec2<f32>,4>(vec2<f32>(-1.,1.),vec2<f32>(1.,1.),vec2<f32>(-1.,-1.),vec2<f32>(1.,-1.));
 let axes=array<vec2<f32>,4>(vec2<f32>(0.,2.),vec2<f32>(-2.,0.),vec2<f32>(2.,0.),vec2<f32>(0.,-2.));
 for(var i=0u;i<4u;i++){
  let outerUv=uv+inner[i]*d*2.;
  let axisUv=uv+axes[i]*d;
  color+=sampleGl(sceneColor,outerUv).rgb*borderWeight(outerUv)*.03125;
  color+=sampleGl(sceneColor,axisUv).rgb*borderWeight(axisUv)*.0625;
  color+=sampleGl(sceneColor,uv+inner[i]*d).rgb*borderWeight(axisUv)*.125;
 }
 if(any((bitcast<vec3<u32>>(color)&vec3<u32>(0x7f800000u))==vec3<u32>(0x7f800000u))){return vec4<f32>(0.,0.,0.,1.);}
 let light=dot(color,vec3<f32>(.2126,.7152,.0722));
 return vec4<f32>(color*smoothstep(lens.threshold.x,lens.threshold.x+lens.threshold.y,light),1.);
}
''';

const lensFeaturesWgsl =
    '''
${PostProcessDescriptor.interfaceWgsl}
$lensUniformWgsl
@group(1) @binding(0) var inputImage:texture_2d<f32>;
fn ghost(uv:vec2<f32>,color:vec3<f32>,offset:f32)->vec3<f32>{
 let coord=clamp(1.-uv+(uv-.5)*offset,vec2<f32>(0.),vec2<f32>(1.));
 let d=clamp(length(.5-coord)/(.5*.7071067811865476),0.,1.);
 return sampleGl(inputImage,coord).rgb*color*pow(1.-d,3.);
}
fn halo(uv:vec2<f32>)->vec3<f32>{
 let texel=1./lens.render.zw;let aspect=vec2<f32>(texel.x/texel.y,1.);
 let delta=(uv-.5)/aspect;
 if(dot(delta,delta)<1e-20){return vec3<f32>(0.);}
 let direction=normalize(delta)*aspect;
 let offset=texel.x*lens.render.x;
 let coord=fract(1.-uv+direction*.3);
 let color=vec3<f32>(sampleGl(inputImage,coord-direction*offset).r,sampleGl(inputImage,coord).g,sampleGl(inputImage,coord+direction*offset).b);
 let wuv=(uv-vec2<f32>(.5,0.))/aspect+vec2<f32>(.5,0.);
 let distance=clamp(length(wuv-.5),0.,1.);
 let value=min(abs(distance-.45)/.25,1.);
 return color*(1.-value*value*(3.-2.*value));
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let uv=vec2<f32>(v.uv.x,1.-v.uv.y);
 var ghosts=vec3<f32>(0.);
 ghosts+=ghost(uv,vec3<f32>(.8,.8,1.),-5.);
 ghosts+=ghost(uv,vec3<f32>(1.,.8,.4),-1.5);
 ghosts+=ghost(uv,vec3<f32>(.9,1.,.8),-.4);
 ghosts+=ghost(uv,vec3<f32>(1.,.8,.4),-.2);
 ghosts+=ghost(uv,vec3<f32>(.9,.7,.7),-.1);
 ghosts+=ghost(uv,vec3<f32>(.5,1.,.4),.7);
 ghosts+=ghost(uv,vec3<f32>(.5,.5,.5),1.);
 ghosts+=ghost(uv,vec3<f32>(1.,1.,.6),2.5);
 ghosts+=ghost(uv,vec3<f32>(.5,.8,1.),10.);
 return vec4<f32>(ghosts*lens.threshold.z+halo(uv)*lens.threshold.w,1.+lens.threshold.w);
}
''';
