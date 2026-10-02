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
 aerial:vec4<f32>, // transmittance, inscatter, sun light, sky light
 geometry:vec4<f32>, // albedo scale, reconstruct normal, correction, reserved
 inputs:vec4<f32>, // normal encoding, mask channel (-1 absent), overlay, world normals
 inverseRadiiSquared:vec4<f32>, geometryOffset:vec4<f32>,
 right:vec4<f32>, up:vec4<f32>,
};
@group(2) @binding(0) var<uniform> atmosphereFrame:AtmosphereFrame;
''';
final atmosphereCompositeWgsl =
    [
      for (final (name, slot) in [
        ('normalImage', 3),
        ('lightingMaskImage', 4),
        ('overlayImage', 5),
      ])
        '''
@group(2) @binding($slot) var $name:texture_2d<f32>;
fn sample_$name(uv:vec2<f32>)->vec4<f32> {
 let size=vec2<i32>(textureDimensions($name));let p=uv*vec2<f32>(size)-.5;
 let i=vec2<i32>(floor(p));let f=fract(p);var value=vec4<f32>(0.);
 for(var y=0;y<2;y++){for(var x=0;x<2;x++){
   value+=textureLoad($name,clamp(i+vec2<i32>(x,y),vec2<i32>(0),size-1),0)*
     select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1);
 }}return value;
}
''',
    ].join() +
    r'''
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
fn safeNormal(value:vec3<f32>,fallback:vec3<f32>)->vec3<f32> {
 let magnitude=length(value);return select(fallback,value/max(magnitude,1e-20),magnitude>1e-10);
}
fn octNormal(e:vec2<f32>)->vec3<f32> {
 var n=vec3<f32>(e,1.-abs(e.x)-abs(e.y));
 if(n.z<0.){n=vec3<f32>((1.-abs(n.yx))*select(vec2<f32>(-1.),vec2<f32>(1.),n.xy>=vec2<f32>(0.)),n.z);}
 return safeNormal(n,vec3<f32>(0.,0.,1.));
}
fn compositeOverlay(color:vec4<f32>,uv:vec2<f32>)->vec4<f32> {
 if(atmosphereFrame.inputs.z==0.){return color;}
 let overlay=sample_overlayImage(uv);let alpha=clamp(overlay.a,0.,1.);
 return vec4<f32>(clamp(color.rgb*(1.-alpha)+overlay.rgb,vec3<f32>(0.),vec3<f32>(65504.)),color.a*(1.-alpha)+alpha);
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
 let f=atmosphereFrame;let coord=vec2<i32>(v.position.xy);
 let input=textureLoad(sceneColor,coord,0);let depth=textureLoad(sceneDepth,coord,0);
 let mid=scenePosition(v.uv,.5);
 let point=scenePosition(v.uv,depth);
 // Camera-relative positions avoid ECEF precision loss. Top-left UV reverses Y,
 // so this cross order faces the camera. Derivatives precede depth branching.
 let reconstructed=safeNormal(cross(dpdy(point),dpdx(point)),-f.forward.xyz);
 var worldRay=normalize(mid);var origin=f.camera.xyz;
 if(f.camera.w>0.){
   worldRay=f.forward.xyz;
   let near=scenePosition(v.uv,sceneNearDepth());
   origin+=(f.worldToEcef*vec4<f32>(near-worldRay*f.forward.w,0.)).xyz*.001;
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
 if(sceneDepthIsBackground(depth)){
   if(f.options.z>0.){return compositeOverlay(vec4<f32>(clamp(input.rgb+sky*(1.-input.a),vec3<f32>(0.),vec3<f32>(65504.)),1.),v.uv);}
   return compositeOverlay(input,v.uv);
 }
 var foreground=input.rgb;
 var end=f.camera.xyz+(f.worldToEcef*vec4<f32>(point,0.)).xyz*.001-f.geometryOffset.xyz;
 var normal=safeNormal(end,vec3<f32>(0.,0.,1.));var degenerate=false;
 if(f.geometry.y>0.){normal=(f.worldToEcef*vec4<f32>(reconstructed,0.)).xyz;}
 else if(f.inputs.x>0.){
   let encoded=sample_normalImage(v.uv).xyz;degenerate=all(encoded==vec3<f32>(0.));
   var local=encoded*2.-1.;if(f.inputs.x>1.){local=octNormal(encoded.xy);}
   var world=local;
   if(f.inputs.w==0.){world=f.right.xyz*local.x+f.up.xyz*local.y-f.forward.xyz*local.z;}
   normal=(f.worldToEcef*vec4<f32>(world,0.)).xyz;
 }
 if(f.geometry.z>0.){
   let sphereNormal=safeNormal(end*f.inverseRadiiSquared.xyz,normal);
   normal=mix(normal,sphereNormal,f.geometry.z);
   end=mix(end,sphereNormal*BOTTOM,f.geometry.z);
 }
 if((f.aerial.z>0. || f.aerial.w>0.) && !degenerate){
   var light=vec3<f32>(0.);
   if(f.aerial.z>0.){light+=atmosphereSunIrradiance(end,normal,f.sun.xyz);}
   if(f.aerial.w>0.){light+=atmosphereSkyIrradiance(end,normal,f.sun.xyz);}
   let relit=foreground*(f.geometry.x/PI)*light;
   var mask=1.;if(f.inputs.y>=0.){mask=clamp(sample_lightingMaskImage(v.uv)[u32(f.inputs.y)],0.,1.);}
   foreground=mix(foreground,relit,mask);
 }
 if(f.options.x>0.){
   let air=atmosphereSegment(origin,end,f.sun.xyz);
   if(f.aerial.x>0.){foreground*=air.transmittance;}
   if(f.aerial.y>0.){foreground+=air.radiance*input.a;}
 }
 if(f.options.z>0.){return compositeOverlay(vec4<f32>(clamp(foreground+sky*(1.-input.a),vec3<f32>(0.),vec3<f32>(65504.)),1.),v.uv);}
 return compositeOverlay(vec4<f32>(clamp(foreground,vec3<f32>(0.),vec3<f32>(65504.)),input.a),v.uv);
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
