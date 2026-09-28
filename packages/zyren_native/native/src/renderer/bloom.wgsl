struct Parameters { values: vec4<f32>, mode: vec4<f32> };
@group(0) @binding(0) var source: texture_2d<f32>;
@group(0) @binding(1) var lower: texture_2d<f32>;
@group(0) @binding(2) var<uniform> parameters: Parameters;
struct Vertex { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex fn vertex(@builtin(vertex_index) index: u32) -> Vertex {
 let uv=vec2<f32>(f32((index<<1u)&2u), f32(index&2u));
 return Vertex(vec4<f32>(uv*vec2<f32>(2.,-2.)+vec2<f32>(-1.,1.),0.,1.), uv);
}
fn bright(c: vec3<f32>) -> vec3<f32> {
 let brightness=max(c.x,max(c.y,c.z));
 let threshold=parameters.values.x;
 let knee=threshold*parameters.values.y;
 var soft=clamp(brightness-threshold+knee,0.,2.*knee);
 soft=soft*soft/(4.*knee+1e-6);
 return c*(max(brightness-threshold,soft)/max(brightness,1e-6));
}
fn load(p:vec2<i32>) -> vec3<f32> {
 let maximum=vec2<i32>(textureDimensions(source))-vec2<i32>(1);
 var c=max(textureLoad(source,clamp(p,vec2<i32>(0),maximum),0).rgb,vec3<f32>(0.));
 if(parameters.mode.x==1.) { c=bright(c); }
 return c;
}
fn sampleSource(uv:vec2<f32>) -> vec3<f32> {
 let p=uv*vec2<f32>(textureDimensions(source))-.5;
 let b=vec2<i32>(floor(p)); let f=fract(p);
 return mix(mix(load(b),load(b+vec2<i32>(1,0)),f.x),mix(load(b+vec2<i32>(0,1)),load(b+vec2<i32>(1)),f.x),f.y);
}
fn low(p:vec2<i32>) -> vec3<f32> {
 return textureLoad(lower,clamp(p,vec2<i32>(0),vec2<i32>(textureDimensions(lower))-vec2<i32>(1)),0).rgb;
}
fn sampleLower(uv:vec2<f32>) -> vec3<f32> {
 let p=uv*vec2<f32>(textureDimensions(lower))-.5;
 let b=vec2<i32>(floor(p)); let f=fract(p);
 return mix(mix(low(b),low(b+vec2<i32>(1,0)),f.x),mix(low(b+vec2<i32>(0,1)),low(b+vec2<i32>(1)),f.x),f.y);
}
@fragment fn down(v:Vertex)->@location(0) vec4<f32> {
 let d=.5/vec2<f32>(textureDimensions(source));
 let c=(sampleSource(v.uv-d)+sampleSource(v.uv+d)+sampleSource(v.uv+vec2<f32>(d.x,-d.y))+sampleSource(v.uv+vec2<f32>(-d.x,d.y)))*.25;
 return vec4<f32>(c,1.);
}
@fragment fn up(v:Vertex)->@location(0) vec4<f32> {
 // A normalized tent kernel prevents gain from depending on pyramid depth.
 let d=1./vec2<f32>(textureDimensions(lower));
 var sum=vec3<f32>(0.);
 for(var y=-1;y<=1;y++) { for(var x=-1;x<=1;x++) {
   let weight=f32((2-abs(x))*(2-abs(y)));
   sum+=sampleLower(v.uv+vec2<f32>(f32(x),f32(y))*d)*weight;
 } }
 return vec4<f32>(mix(sampleSource(v.uv),sum/16.,parameters.values.z),1.);
}
@fragment fn combine(v:Vertex)->@location(0) vec4<f32> {
 let c=textureLoad(source,vec2<i32>(v.position.xy),0);
 let glow=sampleLower(v.uv)*parameters.values.w*clamp(c.a,0.,1.);
 return vec4<f32>(min(c.rgb+glow,vec3<f32>(65504.)),c.a);
}
