// Celestial disk and stellar photometry follow the pinned WebGPU implementation.
// Copyright (c) 2024 Shota Matsuda. MIT, see THIRD_PARTY_NOTICES.md.
const atmosphereSceneUniforms = r'''
struct AtmosphereFrame {
 camera:vec4<f32>, // corrected camera km, orthographic
 sun:vec4<f32>, moon:vec4<f32>, // ECEF direction, intensity
 options:vec4<f32>, // haze, ground, sky, moon radius
 stars:vec4<f32>, // target width/height, point size, normalized intensity
 worldToEcef:mat4x4<f32>, eciToWorld:mat4x4<f32>,
 viewProjection:mat4x4<f32>, moonFixedToEcef:mat4x4<f32>,
 forward:vec4<f32>, // world direction, near
};
@group(2) @binding(0) var<uniform> atmosphereFrame:AtmosphereFrame;
''';
const atmosphereCompositeWgsl = r'''
@group(2) @binding(1) var starImage:texture_2d<f32>;
@group(2) @binding(2) var moonImage:texture_2d<f32>;
fn sampleStarImage(uv:vec2<f32>)->vec3<f32> {
 let size=vec2<i32>(textureDimensions(starImage));let p=uv*vec2<f32>(size)-.5;
 let i=vec2<i32>(floor(p));let f=fract(p);var color=vec3<f32>(0.);
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){
   color+=textureLoad(starImage,clamp(i+vec2<i32>(x,y),vec2<i32>(0),size-1),0).rgb*
     select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);
 }}return color;
}
fn moonColor(uv:vec2<f32>)->vec3<f32> {
 let size=vec2<i32>(textureDimensions(moonImage));let p=uv*vec2<f32>(size)-.5;
 let i=vec2<i32>(floor(p));let f=fract(p);var color=vec3<f32>(0.);
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){
   let q=vec2<i32>(((i.x+x)%size.x+size.x)%size.x,clamp(i.y+y,0,size.y-1));
   color+=textureLoad(moonImage,q,0).rgb*select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);
 }}return color;
}
fn diskCoverage(chord:f32,rad:f32,width:f32)->f32 {
 let edge=4.*pow(sin(rad*.5),2.);return 1.-smoothstep(max(0.,edge-width),edge+width,chord);
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
 let f=atmosphereFrame;let coord=vec2<i32>(v.position.xy);
 let input=textureLoad(sceneColor,coord,0);let depth=textureLoad(sceneDepth,coord,0);
 let ndc=v.uv*vec2<f32>(2.,-2.)+vec2<f32>(-1.,1.);
 let mid=screen.inverseViewProjection*vec4<f32>(ndc,.5,1.);
 var worldRay=normalize(mid.xyz/mid.w);var origin=f.camera.xyz;
 if(f.camera.w>0.){
   worldRay=f.forward.xyz;
   let near=screen.inverseViewProjection*vec4<f32>(ndc,0.,1.);
   origin+=(f.worldToEcef*vec4<f32>(near.xyz/near.w-worldRay*f.forward.w,0.)).xyz*.001;
 }
 let ray=normalize((f.worldToEcef*vec4<f32>(worldRay,0.)).xyz);
 let sunChord=dot(ray-f.sun.xyz,ray-f.sun.xyz);let moonChord=dot(ray-f.moon.xyz,ray-f.moon.xyz);
 // Derivatives must execute before divergent depth and disk branches.
 let sunWidth=max(fwidth(sunChord),1e-10);let moonWidth=max(fwidth(moonChord),1e-10);
 var sky=vec3<f32>(0.);
 if(f.options.z>0.){
   let air=atmosphereSky(origin,ray,f.sun.xyz,f.options.y>0.);
   var distant=sampleStarImage(v.uv);
   if(f.camera.w==0.){
     let solar=SOLAR*SUN_LUMINANCE/(PI*SUN_RADIUS*SUN_RADIUS)*f.sun.w;
     distant=mix(distant,solar,diskCoverage(sunChord,SUN_RADIUS,sunWidth)*select(0.,1.,f.sun.w>0.));
     let radius=f.options.w;let coverage=diskCoverage(moonChord,radius,moonWidth);
     if(coverage>0. && f.moon.w>0.){
       let p=ray*dot(f.moon.xyz,ray)-f.moon.xyz;
       let n=normalize((p-ray*sqrt(max(radius*radius-dot(p,p),0.)))/radius);
       let fixed=(transpose(f.moonFixedToEcef)*vec4<f32>(n,0.)).xyz;
       let uv=vec2<f32>(atan2(fixed.y,fixed.x)/(2.*PI)+.5,acos(clamp(fixed.z,-1.,1.))/PI);
       let cosL=dot(n,f.sun.xyz);let cosV=dot(n,-ray);let s=dot(f.sun.xyz,-ray)-cosL*cosV;
       let t=mix(1.,max(max(cosL,cosV),.1),smoothstep(0.,.1,s));
       let a=(1./PI)*(1.-.5/1.33+.17/1.13);let b=(1./PI)*(.45/1.09);
       let diffuse=max(cosL,0.)*(a+b*s/t);
       let lunar=SOLAR*SUN_LUMINANCE*(2.5e-6/(PI*radius*radius))*diffuse*moonColor(uv)*f.moon.w;
       distant=mix(distant,lunar,coverage);
     }
   }
   sky=distant*air.transmittance+air.radiance;
 }
 if(depth>=1.){
   if(f.options.z>0.){return vec4<f32>(clamp(input.rgb+sky*(1.-input.a),vec3<f32>(0.),vec3<f32>(65504.)),1.);}
   return input;
 }
 var foreground=input.rgb;
 if(f.options.x>0.){
   let point=screen.inverseViewProjection*vec4<f32>(ndc,depth,1.);
   let end=f.camera.xyz+(f.worldToEcef*vec4<f32>(point.xyz/point.w,0.)).xyz*.001;
   let air=atmosphereSegment(origin,end,f.sun.xyz);
   foreground=foreground*air.transmittance+air.radiance*input.a;
 }
 if(f.options.z>0.){return vec4<f32>(clamp(foreground+sky*(1.-input.a),vec3<f32>(0.),vec3<f32>(65504.)),1.);}
 return vec4<f32>(clamp(foreground,vec3<f32>(0.),vec3<f32>(65504.)),input.a);
}
''';
const atmosphereStarsWgsl = r'''
struct StarRecord { direction:vec4<f32>,color:vec4<f32> };
@group(2) @binding(1) var<storage,read> catalogue:array<StarRecord>;
struct StarVertex { @builtin(position) position:vec4<f32>, @location(0) color:vec3<f32> };
@vertex fn vertex(@builtin(vertex_index) index:u32,@builtin(instance_index) instance:u32)->StarVertex {
 let f=atmosphereFrame;let star=catalogue[instance];
 let world=f.eciToWorld*vec4<f32>(star.direction.xyz,0.);
 let clip=f.viewProjection*world;var v:StarVertex;v.color=vec3<f32>(0.);v.position=vec4<f32>(2.,2.,.5,1.);
 if(clip.w<=0. || f.camera.w>0. || f.stars.w==0.){return v;}
 let corners=array<vec2<f32>,6>(vec2<f32>(-1.,-1.),vec2<f32>(1.,-1.),vec2<f32>(-1.,1.),vec2<f32>(-1.,1.),vec2<f32>(1.,-1.),vec2<f32>(1.,1.));
 let offset=corners[index]*f.stars.z/f.stars.xy;
 v.position=vec4<f32>(clip.xy/clip.w+offset,.5,1.);
 // The Y row length of the rotated view-projection is the vertical focal scale.
 let py=length(vec3<f32>(f.viewProjection[0][1],f.viewProjection[1][1],f.viewProjection[2][1]));
 let solid=pow(f.stars.z*2./(f.stars.y*py),2.);
 let luminance=10.8e4*pow(10.,-.4*star.direction.w)/(4.25e10*solid);
 v.color=min(star.color.rgb*luminance*f.stars.w,vec3<f32>(65504.));return v;
}
@fragment fn fragment(v:StarVertex)->@location(0) vec4<f32>{return vec4<f32>(v.color,0.);}
''';
