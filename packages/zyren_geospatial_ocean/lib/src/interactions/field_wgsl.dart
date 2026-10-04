const _config = '''
struct Config { grid:vec4<f32>, damping:vec4<f32>, source:vec4<f32>, flow:vec4<f32>, shift:vec4<f32> };
@group(0) @binding(0) var<uniform> config:Config;
@group(0) @binding(1) var<storage,read> cells:array<vec4<f32>>;
fn readCell(p:vec2<i32>)->vec4<f32> {
 let n=i32(config.grid.x);if(any(p<vec2(0))||any(p>=vec2(n))){return vec4(0.);}
 return cells[u32(p.y)*u32(n)+u32(p.x)];
}
''';
const oceanInteractionUpdateWgsl =
    '''
$_config
@group(0) @binding(2) var<storage,read_write> output:array<vec4<f32>>;
struct Event { positionRadius:vec4<f32>, velocity:vec4<f32> };
@group(0) @binding(3) var<storage,read> events:array<Event>;
@group(0) @binding(4) var foamSources:texture_2d<f32>;
fn previousFoam(p:vec2<f32>)->f32 {
 let cell=vec2<i32>(floor(p));let f=fract(p);
 return mix(mix(readCell(cell).z,readCell(cell+vec2(1,0)).z,f.x),
   mix(readCell(cell+vec2(0,1)).z,readCell(cell+vec2(1,1)).z,f.x),f.y);
}
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
 let n=u32(config.grid.x);if(id.x>=n||id.y>=n){return;}
 let p=vec2<i32>(id.xy);let at=id.y*n+id.x;let old=cells[at];
 let edge=min(min(id.x,id.y),min(n-1u-id.x,n-1u-id.y));
 let ramp=clamp(1.-f32(edge)/config.damping.z,0.,1.);
 let damping=config.damping.x+config.damping.y*ramp*ramp;
 let dt=config.grid.z;let dx=config.grid.y;let c=config.grid.w;
 let lap=readCell(p+vec2(1,0)).x+readCell(p-vec2(1,0)).x+
   readCell(p+vec2(0,1)).x+readCell(p-vec2(0,1)).x-4.*old.x;
 var injection=0.;var eventFoam=0.;
 if(config.source.y>.5){
   let world=(vec2<f32>(id.xy)-vec2(.5*f32(n-1u)))*dx;
   for(var i=0u;i<u32(config.source.x);i++){
     let event=events[i];let delta=(world-event.positionRadius.xy)/event.positionRadius.z;
     let r2=dot(delta,delta);if(r2>=1.){continue;}
     let envelope=(1.-r2)*(1.-r2)*exp(-4.*r2);
     let speed=length(event.velocity.xy);
     var shape=1.-4.*r2;
     if(speed>.001){shape=dot(delta,event.velocity.xy/speed)*4.;}
     injection+=event.positionRadius.w*envelope*shape;
     eventFoam+=event.positionRadius.w*envelope*min(4.,speed);
   }
 }
 var h=2.*old.x-old.y+(c*dt/dx)*(c*dt/dx)*lap-damping*dt*(old.x-old.y)+injection;
 h=clamp(h,-config.damping.w,config.damping.w);
 var previous=clamp(old.x+injection,-config.damping.w,config.damping.w);
 if(edge==0u){h=0.;previous=0.;}
 let transported=previousFoam(vec2<f32>(id.xy)-config.flow.xy*dt/dx)*exp(-dt/config.source.z);
 let rate=textureLoad(foamSources,p,0).xy;
 let gain=config.source.w;
 let foam=clamp(1.-(1.-transported)*exp(-gain*(max(0.,rate.x+rate.y)*dt+eventFoam)),0.,1.);
 output[at]=vec4(h,previous,foam,0.);
}
''';
const oceanInteractionPublishWgsl =
    '''
$_config
@group(0) @binding(2) var output:texture_storage_2d<rgba32float,write>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
 let n=u32(config.grid.x);if(id.x>=n||id.y>=n){return;}
 let p=vec2<i32>(id.xy);let value=cells[id.y*n+id.x];
 let slope=vec2(readCell(p+vec2(1,0)).x-readCell(p-vec2(1,0)).x,
   readCell(p+vec2(0,1)).x-readCell(p-vec2(0,1)).x)/(2.*config.grid.y);
 textureStore(output,p,vec4(value.x,slope,value.z));
}
''';
const oceanInteractionShiftWgsl =
    '''
$_config
@group(0) @binding(2) var<storage,read_write> output:array<vec4<f32>>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>) {
 let n=u32(config.grid.x);if(id.x>=n||id.y>=n){return;}
 output[id.y*n+id.x]=readCell(vec2<i32>(id.xy)+vec2<i32>(config.shift.xy));
}
''';
