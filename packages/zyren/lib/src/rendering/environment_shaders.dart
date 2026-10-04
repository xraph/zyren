part of '../resources/resource_scope.dart';

const _environmentCommonWgsl = '''
const PI: f32 = 3.14159265359;
fn xi(i:u32)->vec2<f32> { return vec2<f32>((f32(i)+.5)/f32(SAMPLES),f32(reverseBits(i))*2.3283064365386963e-10); }
fn basis(n:vec3<f32>)->mat3x3<f32> {
 let up=select(vec3<f32>(0.,0.,1.),vec3<f32>(1.,0.,0.),abs(n.z)>.999);
 let t=normalize(cross(up,n)); return mat3x3<f32>(t,cross(n,t),n);
}
fn direction(uv:vec2<f32>)->vec3<f32> {
 let p=(uv.x-.5)*2.*PI; let t=uv.y*PI;
 return vec3<f32>(cos(p)*sin(t),cos(t),sin(p)*sin(t));
}
fn ggx(x:vec2<f32>,rough:f32)->vec3<f32> {
 let a=max(rough*rough,.002025); let c=sqrt((1.-x.y)/(1.+(a*a-1.)*x.y));
 let s=sqrt(max(0.,1.-c*c)); let p=x.x*2.*PI;
 return vec3<f32>(cos(p)*s,sin(p)*s,c);
}
''';
const _environmentSourceWgsl = '''
@group(0) @binding(0) var source: texture_2d<f32>;
fn texel(p:vec2<i32>)->vec3<f32> {
 let d=vec2<i32>(textureDimensions(source));
 return max(textureLoad(source,vec2<i32>((p.x%d.x+d.x)%d.x,clamp(p.y,0,d.y-1)),0).rgb,vec3<f32>(0.));
}
fn radiance(n:vec3<f32>)->vec3<f32> {
 let uv=vec2<f32>(atan2(n.z,n.x)/(2.*PI)+.5,acos(clamp(n.y,-1.,1.))/PI);
 let p=uv*vec2<f32>(textureDimensions(source))-.5; let i=vec2<i32>(floor(p)); let f=fract(p);
 return mix(mix(texel(i),texel(i+vec2<i32>(1,0)),f.x),mix(texel(i+vec2<i32>(0,1)),texel(i+vec2<i32>(1,1)),f.x),f.y);
}
''';
const _irradianceWgsl =
    '''
$_environmentSourceWgsl
@group(0) @binding(1) var output: texture_storage_2d<rgba16float,write>;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
 let d=textureDimensions(output); if(any(id.xy>=d)){return;}
 let n=direction((vec2<f32>(id.xy)+.5)/vec2<f32>(d)); let frame=basis(n);
 var sum=vec3<f32>(0.);
 for(var i=0u;i<SAMPLES;i++) {
   let x=xi(i);let p=x.x*2.*PI;let s=sqrt(x.y);
   sum+=radiance(frame*vec3<f32>(cos(p)*s,sin(p)*s,sqrt(1.-x.y)));
 }
 textureStore(output,vec2<i32>(id.xy),vec4<f32>(min(sum*(PI/f32(SAMPLES)),vec3<f32>(65504.)),1.));
}
''';
const _specularWgsl =
    '''
$_environmentSourceWgsl
@group(0) @binding(1) var output: texture_storage_3d<rgba16float,write>;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
 let d=textureDimensions(output); if(any(id>=d)){return;}
 let n=direction((vec2<f32>(id.xy)+.5)/vec2<f32>(d.xy)); let frame=basis(n);
 let rough=max(f32(id.z)/f32(d.z-1u),.045);var sum=vec3<f32>(0.);var weight=0.;
 for(var i=0u;i<SAMPLES;i++) {
   let h=frame*ggx(xi(i),rough);let l=reflect(-n,h);let nl=max(dot(n,l),0.);
   if(nl>0.) {sum+=radiance(l)*nl;weight+=nl;}
 }
 textureStore(output,vec3<i32>(id),vec4<f32>(min(sum/max(weight,1e-6),vec3<f32>(65504.)),1.));
}
''';
const _brdfWgsl = '''
$ggxEnergyWgsl
@group(0) @binding(1) var output: texture_storage_2d<rgba16float,write>;
@compute @workgroup_size(8,8,1) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
 let d=textureDimensions(output); if(any(id.xy>=d)){return;}
 let uv=vec2<f32>(id.xy)/vec2<f32>(d-vec2(1u));
 textureStore(output,vec2<i32>(id.xy),vec4(ggx_energy_integral(uv.x,uv.y,SAMPLES),0.,1.));
}
''';
