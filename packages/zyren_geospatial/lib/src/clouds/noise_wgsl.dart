// Source equations: three-geospatial, TileableVolumeNoise and GLM.
// Redistribution notices: licenses/cloud-noise.txt.
const cloudNoiseWgsl = r'''
@group(0) @binding(2) var<storage,read> cloudHash:array<f32>;
fn periodic(x:vec3<f32>,period:vec3<f32>)->vec3<f32>{return x-floor(x/period)*period;}
fn permute(x:f32)->f32{let v=(x*34.+1.)*x;return v-floor(v*(1./289.))*289.;}
// The source's four-dimensional periodic Perlin is sampled with w=0, repeat.w=1.
// Only the eight w=0 corners contribute. Retain the 4D gradient normalization.
fn perlin(point:vec3<f32>,frequency:vec3<f32>)->f32 {
 let position=point*frequency;let base=periodic(floor(position),frequency);
 let f=fract(position);let fade=f*f*f*(f*(f*6.-vec3<f32>(15.))+vec3<f32>(10.));
 var values:array<f32,8>;
 for(var z=0;z<2;z++){for(var y=0;y<2;y++){for(var x=0;x<2;x++){
   let corner=vec3<f32>(f32(x),f32(y),f32(z));let i=periodic(base+corner,frequency);
   let h=permute(permute(permute(permute(i.x)+i.y)+i.z));
   let gx=h/7.;let gy=floor(gx)/7.;let gz=floor(gy)/6.;
   var g=vec4<f32>(fract(vec3<f32>(gx,gy,gz))-.5,0.);
   g.w=.75-abs(g.x)-abs(g.y)-abs(g.z);
   let s=select(0.,1.,g.w<=0.);
   g.x-=s*(select(0.,1.,g.x>=0.)-.5);g.y-=s*(select(0.,1.,g.y>=0.)-.5);
   g*=1.79284291400159-.85373472095314*dot(g,g);
   values[u32(x+y*2+z*4)]=dot(g.xyz,f-corner);
 }}}
 let low=mix(mix(values[0],values[1],fade.x),mix(values[2],values[3],fade.x),fade.y);
 let high=mix(mix(values[4],values[5],fade.x),mix(values[6],values[7],fade.x),fade.y);
 return 2.2*mix(low,high,fade.z);
}
fn perlinFbm(point:vec3<f32>,frequency:vec3<f32>,octaves:i32)->f32 {
 var f=frequency;var value=0.;var weight=1.;var total=0.;
 for(var i=0;i<octaves;i++){value+=perlin(point,f)*weight;total+=weight;weight*=.5;f*=2.;}
 return value/total;
}
fn worley(point:vec3<f32>,frequency:f32)->f32 {
 let cell=point*frequency;let base=floor(cell);var distance=1e10;
 for(var x=-1;x<=1;x++){for(var y=-1;y<=1;y++){for(var z=-1;z<=1;z++){
   let tile=base+vec3<f32>(f32(x),f32(y),f32(z));
   let wrapped=periodic(tile,vec3<f32>(frequency));
   // All source Worley frequencies are integers, so noise(mod(tile,...))
   // evaluates its integer lattice hash without interpolation.
   let n=wrapped.x+wrapped.y*57.+wrapped.z*113.;
   let random=cloudHash[u32(n)];
   let delta=cell-tile-vec3<f32>(random);distance=min(distance,dot(delta,delta));
 }}}
 return clamp(distance,0.,1.);
}
fn worleyFbm(point:vec3<f32>,frequency:f32)->f32 {
 var value=0.;var amplitude=.4;var f=frequency;
 for(var i=0;i<4;i++){value+=amplitude*(1.-worley(point,f));f*=2.;amplitude*=.95;}
 return value;
}
fn weather(point:vec3<f32>)->vec4<f32> {
 let middle=smoothstep(1.,1.4,worleyFbm(point+vec3<f32>(.5),8.));
 let low=smoothstep(.8,1.4,worleyFbm(point,16.));
 let high=smoothstep(-.5,.5,perlinFbm(point,vec3<f32>(6.,12.,1.),8));
 return vec4<f32>(clamp(low-middle,0.,1.),middle,high,1.);
}
fn shape(point:vec3<f32>)->f32 {
 let p=clamp(perlinFbm(point,vec3<f32>(8.),3),0.,1.);
 let a=vec3<f32>(1.-worley(point,8.),1.-worley(point,32.),1.-worley(point,56.));
 let perlinWorley=mix(dot(a,vec3<f32>(.625,.25,.125)),1.,p);
 let b=vec4<f32>(a.x,1.-worley(point,16.),a.y,1.-worley(point,64.));
 let fbm=vec3<f32>(dot(b.xyz,vec3<f32>(.625,.25,.125)),dot(b.yzw,vec3<f32>(.625,.25,.125)),dot(b.zw,vec2<f32>(.75,.25)));
 let threshold=dot(fbm,vec3<f32>(.625,.25,.125))-1.;
 return (perlinWorley-threshold)/(1.-threshold);
}
fn detail(point:vec3<f32>)->f32 {
 let noise=vec4<f32>(1.-worley(point,2.),1.-worley(point,4.),1.-worley(point,8.),1.-worley(point,16.));
 let fbm=vec3<f32>(dot(noise.xyz,vec3<f32>(.625,.25,.125)),dot(noise.yzw,vec3<f32>(.625,.25,.125)),dot(noise.zw,vec2<f32>(.75,.25)));
 return dot(fbm,vec3<f32>(.625,.25,.125));
}
fn perlinVector(point:vec3<f32>)->vec3<f32> {
 return vec3<f32>(perlinFbm(point,vec3<f32>(12.),3),
   perlinFbm(point.yzx+vec3<f32>(-19.1,33.4,47.2),vec3<f32>(12.),3),
   perlinFbm(point.zxy+vec3<f32>(74.2,-124.5,99.4),vec3<f32>(12.),3));
}
fn turbulence(point:vec3<f32>)->vec4<f32> {
 let x0=perlinVector(point-vec3<f32>(.1,0.,0.));let x1=perlinVector(point+vec3<f32>(.1,0.,0.));
 let y0=perlinVector(point-vec3<f32>(0.,.1,0.));let y1=perlinVector(point+vec3<f32>(0.,.1,0.));
 let z0=perlinVector(point-vec3<f32>(0.,0.,.1));let z1=perlinVector(point+vec3<f32>(0.,0.,.1));
 let curl=vec3<f32>(y1.z-y0.z-z1.y+z0.y,z1.x-z0.x-x1.z+x0.z,x1.y-x0.y-y1.x+y0.x)*5.;
 let direction=curl/max(length(curl),1e-10);
 return vec4<f32>(direction*.5+vec3<f32>(.5),1.);
}
''';
