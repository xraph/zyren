const oceanFoamWgsl = '''
struct FoamSettings { anchor:vec4<f32>, east:vec4<f32>, north:vec4<f32>, up:vec4<f32>, shore:vec4<f32>, reserved:vec4<f32> };
@group(0) @binding(0) var<uniform> foam:FoamSettings;
@group(0) @binding(1) var depths:texture_2d<f32>;
@group(0) @binding(2) var emission:texture_storage_2d<rgba32float,write>;
@compute @workgroup_size(8,8) fn main(@builtin(global_invocation_id) id:vec3<u32>){
  let n=u32(foam.east.w);if(id.x>=n||id.y>=n){return;}
  let uv=vec2<f32>(id.xy)/f32(n-1u)-vec2(.5);
  let point=foam.anchor.xyz+(foam.east.xyz*uv.x+foam.north.xyz*uv.y)*foam.anchor.w;
  let surface=waterSurface(point,foam.anchor.w/f32(n-1u));
  let whitecap=foam.up.w*clamp((foam.north.w-surface.compression)/foam.north.w,0.,1.);
  let depth=textureLoad(depths,vec2<i32>(id.xy),0);
  var shore=0.;
  // Mismatched mean levels are unavailable rather than silently shifting a coast.
  if(depth.y>.5 && depth.x>0. && abs(foam.shore.w-water.originWeighted.w)<.001){
    let wetDepth=max(0.,depth.x+dot(surface.offset,foam.up.xyz)-water.originWeighted.w);
    let shallow=clamp(1.-wetDepth/foam.shore.y,0.,1.);
    let cosine=clamp(dot(surface.normal,foam.up.xyz),.01,1.);
    let slope=sqrt(max(0.,1.-cosine*cosine))/cosine;
    shore=foam.shore.x*shallow*shallow*clamp(slope/foam.shore.z,0.,1.);
  }
  textureStore(emission,vec2<i32>(id.xy),vec4(whitecap,shore,0.,0.));
}
''';
