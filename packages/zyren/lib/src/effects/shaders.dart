const postProcessingWgsl = r'''
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var<uniform> options: vec4<f32>;
@group(0) @binding(2) var glow: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i:u32) -> @builtin(position) vec4<f32> {
  let p = array<vec2<f32>,3>(vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));
  return vec4(p[i],0.,1.);
}
fn load(t: texture_2d<f32>, p:vec2<i32>) -> vec4<f32> {
  return textureLoad(t,clamp(p,vec2(0),vec2<i32>(textureDimensions(t))-1),0);
}
fn associated(c:vec4<f32>) -> vec4<f32> { return vec4(c.rgb*c.a,c.a); }
fn straight(c:vec4<f32>) -> vec4<f32> {
  if c.a <= 0. { return vec4(0.); }
  return vec4(c.rgb/c.a,c.a);
}
fn sampleLinear(t: texture_2d<f32>, p:vec2<f32>) -> vec4<f32> {
  let q = p-vec2(.5); let i=vec2<i32>(floor(q)); let f=fract(q);
  return mix(mix(load(t,i),load(t,i+vec2(1,0)),f.x),
    mix(load(t,i+vec2(0,1)),load(t,i+vec2(1,1)),f.x),f.y);
}
fn sampleAssociated(p:vec2<f32>) -> vec4<f32> {
  let q=p-vec2(.5); let i=vec2<i32>(floor(q)); let f=fract(q);
  return mix(mix(associated(load(source,i)),associated(load(source,i+vec2(1,0))),f.x),
    mix(associated(load(source,i+vec2(0,1))),associated(load(source,i+vec2(1,1))),f.x),f.y);
}
fn bright(p:vec2<i32>) -> vec4<f32> {
  let c = load(source,p); let light = max(c.r,max(c.g,c.b));
  let knee = options.x*options.y;
  let soft = clamp(light-options.x+knee,0.,2.*knee);
  let contribution=max(light-options.x,soft*soft/max(4.*knee,0.00001));
  return vec4(c.rgb*c.a*(contribution/max(light,0.00001)),0.);
}
@fragment fn extract(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> {
  let i=vec2<i32>(p.xy)*2;
  return (bright(i)+bright(i+vec2(1,0))+bright(i+vec2(0,1))+bright(i+vec2(1,1)))*.25;
}
fn blur(p:vec2<f32>, axis:vec2<f32>) -> vec4<f32> {
  let weights=array<f32,5>(.227027027,.194594595,.121621622,.054054054,.016216216);
  var c=sampleLinear(source,p)*weights[0];
  for(var i=1;i<5;i++) {
    let offset=axis*f32(i)*options.w;
    c += (sampleLinear(source,p+offset)+sampleLinear(source,p-offset))*weights[i];
  }
  return c;
}
@fragment fn horizontal(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> { return blur(p.xy,vec2(1.,0.)); }
@fragment fn vertical(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> { return blur(p.xy,vec2(0.,1.)); }
@fragment fn composite(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> {
  let base=load(source,vec2<i32>(p.xy));
  let light=sampleLinear(glow,p.xy*.5).rgb*options.z;
  let halo=clamp(max(light.r,max(light.g,light.b)),0.,1.);
  let alpha=base.a+halo*(1.-base.a);
  return straight(vec4(min(base.rgb*base.a+light,vec3(65504.)),alpha));
}
fn contrast(c:vec4<f32>) -> f32 {
  let l=dot(c.rgb,vec3(.2126,.7152,.0722))*c.a;
  return l/(1.+l);
}
@fragment fn antialias(@builtin(position) p:vec4<f32>) -> @location(0) vec4<f32> {
  let i=vec2<i32>(p.xy); let c=load(source,i);
  let n=load(source,i+vec2(0,-1)); let s=load(source,i+vec2(0,1));
  let e=load(source,i+vec2(1,0)); let w=load(source,i+vec2(-1,0));
  let a=vec4(n.a,s.a,e.a,w.a); let l=vec4(contrast(n),contrast(s),contrast(e),contrast(w));
  let ar=max(max(a.x,a.y),max(a.z,a.w))-min(min(a.x,a.y),min(a.z,a.w));
  let lr=max(max(l.x,l.y),max(l.z,l.w))-min(min(l.x,l.y),min(l.z,l.w));
  let edge=select(l,a,ar>lr);
  let low=min(min(edge.x,edge.y),min(edge.z,edge.w));
  let high=max(max(edge.x,edge.y),max(edge.z,edge.w));
  if high-low < max(.03125,high*.125) { return c; }
  let gradient=vec2(edge.z-edge.w,edge.y-edge.x);
  if dot(gradient,gradient) < .000001 { return c; }
  let tangent=normalize(vec2(-gradient.y,gradient.x));
  return straight(associated(c)*.5+(sampleAssociated(p.xy+tangent*.75)+sampleAssociated(p.xy-tangent*.75))*.25);
}
''';
