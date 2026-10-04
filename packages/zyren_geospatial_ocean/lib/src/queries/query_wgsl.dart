const oceanCanonicalQueryWgsl = '''
struct Mode { coefficient: vec4<f32>, differential: vec4<f32>, frequency: vec4<f32>, }
@group(0) @binding(0) var<uniform> config: vec4<u32>;
@group(0) @binding(1) var<storage, read> modes: array<Mode>;
@group(0) @binding(2) var<storage, read> coordinates: array<vec2<f32>>;
@group(0) @binding(3) var<storage, read_write> output: array<vec4<f32>>;
var<workgroup> first: array<vec4<f32>,64>;
var<workgroup> second: array<vec4<f32>,64>;
var<workgroup> third: array<vec4<f32>,64>;
@compute @workgroup_size(64)
fn main(@builtin(workgroup_id) group: vec3<u32>, @builtin(local_invocation_index) lane: u32) {
  if (group.x >= config.y) { return; }
  var a=vec4(0.0); var b=vec4(0.0); var d=vec4(0.0);
  for (var i=lane; i<config.x; i+=64u) {
    let m=modes[i];
    let uv=coordinates[group.x*config.z+u32(m.frequency.z)];
    let turns=m.frequency.x*uv.x+m.frequency.y*uv.y;
    let angle=clamp((turns-floor(turns+0.5))*6.283185307179586,-3.1415925,3.1415925);
    let c=cos(angle); let s=sin(angle);
    let r=m.coefficient.x*c-m.coefficient.y*s;
    let im=m.coefficient.x*s+m.coefficient.y*c;
    let vr=m.coefficient.z*c-m.coefficient.w*s;
    let vi=m.coefficient.z*s+m.coefficient.w*c;
    let kx=m.differential.x; let kz=m.differential.y;
    let ax=m.differential.z; let az=m.differential.w;
    a+=vec4(r,ax*im,az*im,-kx*im);
    b+=vec4(-kz*im,ax*vi,vr,az*vi);
    d+=vec4(ax*kx*r,ax*kz*r,az*kx*r,az*kz*r);
  }
  first[lane]=a; second[lane]=b; third[lane]=d;
  workgroupBarrier();
  for (var stride=32u; stride>0u; stride/=2u) {
    if (lane<stride) {
      first[lane]+=first[lane+stride];
      second[lane]+=second[lane+stride];
      third[lane]+=third[lane+stride];
    }
    workgroupBarrier();
  }
  if (lane==0u) {
    output[3u*group.x]=first[0];
    output[3u*group.x+1u]=second[0];
    output[3u*group.x+2u]=third[0];
  }
}
''';
