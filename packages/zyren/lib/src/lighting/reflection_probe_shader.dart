part of 'reflection_probes.dart';
const _probeConversion = r'''
@group(0) @binding(0) var px:texture_2d<f32>;
@group(0) @binding(1) var nx:texture_2d<f32>;
@group(0) @binding(2) var py:texture_2d<f32>;
@group(0) @binding(3) var ny:texture_2d<f32>;
@group(0) @binding(4) var pz:texture_2d<f32>;
@group(0) @binding(5) var nz:texture_2d<f32>;
@group(0) @binding(6) var filtering:sampler;
@group(0) @binding(7) var output:texture_storage_2d<rgba16float,write>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
 let size=textureDimensions(output); if(any(id.xy>=size)){return;}
 let uv=(vec2<f32>(id.xy)+.5)/vec2<f32>(size);
 let phi=(uv.x-.5)*6.28318530718; let theta=uv.y*3.14159265359;
 let d=vec3(cos(phi)*sin(theta),cos(theta),sin(phi)*sin(theta));
 let a=abs(d); var c=vec4(0.);
 if(a.x>=a.y&&a.x>=a.z){
   if(d.x>0.){c=textureSampleLevel(px,filtering,vec2(d.z,-d.y)/a.x*.5+.5,0.);}
   else {c=textureSampleLevel(nx,filtering,vec2(-d.z,-d.y)/a.x*.5+.5,0.);}
 } else if(a.y>=a.z){
   if(d.y>0.){c=textureSampleLevel(py,filtering,vec2(d.x,d.z)/a.y*.5+.5,0.);}
   else {c=textureSampleLevel(ny,filtering,vec2(d.x,-d.z)/a.y*.5+.5,0.);}
 } else {
   if(d.z>0.){c=textureSampleLevel(pz,filtering,vec2(-d.x,-d.y)/a.z*.5+.5,0.);}
   else {c=textureSampleLevel(nz,filtering,vec2(d.x,-d.y)/a.z*.5+.5,0.);}
 }
 textureStore(output,vec2<i32>(id.xy),vec4(max(c.rgb,vec3(0.)),1.));
}
''';
