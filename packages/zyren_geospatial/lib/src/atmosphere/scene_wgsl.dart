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
 geometry:vec4<f32>, // albedo scale, reconstruct normal, correction, cloud inputs
 inputs:vec4<f32>, // normal encoding, mask channel (-1 absent), overlay, world normals
 inverseRadiiSquared:vec4<f32>, geometryOffset:vec4<f32>,
 right:vec4<f32>, up:vec4<f32>,
 lunar:vec4<f32>, // phase-scaled moon irradiance, night fill, relighting enabled
 fogColorStart:vec4<f32>, fogEnd:vec4<f32>, // linear RGB, start/end metres (end zero disables)
};
@group(2) @binding(0) var<uniform> atmosphereFrame:AtmosphereFrame;
''';
final atmosphereCompositeWgsl =
    [
      for (final (name, slot) in [
        ('normalImage', 3),
        ('lightingMaskImage', 4),
        ('overlayImage', 5),
        ('cloudImage', 6),
        ('cloudDepthVelocityShadow', 7),
        ('cloudTransmission', 8),
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
@group(2) @binding(9) var mediumTransport:texture_2d<f32>;
struct AerialMedium { transmittance:vec3<f32>, entry:f32, radiance:vec3<f32>, exit:f32 };
fn aerialMedium(uv:vec2<f32>)->AerialMedium {
 if(atmosphereFrame.lunar.w<.5){return AerialMedium(vec3(1.),0.,vec3(0.),0.);}
 let size=vec2<i32>(textureDimensions(mediumTransport));let halfSize=vec2(size.x/2,size.y);
 let p=clamp(vec2<i32>(uv*vec2<f32>(halfSize)),vec2(0),halfSize-vec2(1));
 let t=textureLoad(mediumTransport,p,0);let s=textureLoad(mediumTransport,p+vec2(halfSize.x,0),0);
 return AerialMedium(clamp(t.rgb,vec3(0.),vec3(1.)),max(0.,t.a)*.001,max(s.rgb,vec3(0.)),max(0.,s.a)*.001);
}
fn airTransport(color:vec3<f32>,alpha:f32,origin:vec3<f32>,end:vec3<f32>,shadow:f32)->vec3<f32>{
 if(atmosphereFrame.options.x<=0. || distance(origin,end)<1e-7){return color;}
 let air=atmosphereSegmentShadow(origin,end,atmosphereFrame.sun.xyz,shadow);
 var value=color;
 if(atmosphereFrame.aerial.x>0.){value*=air.transmittance;}
 if(atmosphereFrame.aerial.y>0.){value+=air.radiance*alpha;}
 return value;
}
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
fn fogOpacity(distanceMetres:f32)->f32 {
 let f=atmosphereFrame;
 if(f.fogEnd.x<=0.){return 0.;}
 return smoothstep(f.fogColorStart.w,f.fogEnd.x,distanceMetres);
}
fn compositeOverlay(color:vec4<f32>,uv:vec2<f32>,distanceMetres:f32)->vec4<f32> {
 var result=mix(color,vec4(atmosphereFrame.fogColorStart.rgb,1.),fogOpacity(distanceMetres));
 if(atmosphereFrame.geometry.w>0.){
  let clouds=sample_cloudImage(uv);let alpha=clamp(clouds.a,0.,1.);
  let cloudFog=fogOpacity(max(0.,sample_cloudDepthVelocityShadow(uv).x));
  let cloudColor=mix(clouds.rgb,atmosphereFrame.fogColorStart.rgb*alpha,cloudFog);
  result=vec4<f32>(result.rgb*(1.-alpha)+cloudColor,result.a*(1.-alpha)+alpha);
 }
 if(atmosphereFrame.inputs.z==0.){return vec4<f32>(clamp(result.rgb,vec3<f32>(0.),vec3<f32>(65504.)),result.a);}
 let overlay=sample_overlayImage(uv);let alpha=clamp(overlay.a,0.,1.);
 return vec4<f32>(clamp(result.rgb*(1.-alpha)+overlay.rgb,vec3<f32>(0.),vec3<f32>(65504.)),result.a*(1.-alpha)+alpha);
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
 let f=atmosphereFrame;let coord=vec2<i32>(v.position.xy);
 let input=textureLoad(sceneColor,coord,0);let depth=textureLoad(sceneDepth,coord,0);
 var shadowLength=0.;var cloudTransmission=1.;
 if(f.geometry.w>0.){shadowLength=max(0.,sample_cloudDepthVelocityShadow(v.uv).w);cloudTransmission=clamp(sample_cloudTransmission(v.uv).r,0.,1.);}
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
 let medium=aerialMedium(v.uv);let hasMedium=medium.exit>medium.entry;
 let skyOrigin=origin+ray*select(0.,medium.exit,hasMedium);
 let sunChord=dot(ray-f.sun.xyz,ray-f.sun.xyz);let moonChord=dot(ray-f.moon.xyz,ray-f.moon.xyz);
 // Derivatives must execute before divergent depth and disk branches.
 let sunWidth=max(fwidth(sunChord),1e-10);let moonWidth=max(fwidth(moonChord),1e-10);
 let fogDistance=select(length(point),f.fogEnd.x,sceneDepthIsBackground(depth));
 // Keep derivatives above this branch. Fully hidden pixels skip sky/air lighting.
 if(f.fogEnd.x>0. && fogDistance>=f.fogEnd.x){
   return compositeOverlay(vec4(f.fogColorStart.rgb,1.),v.uv,fogDistance);
 }
 var sky=vec3<f32>(0.);
 if(f.options.z>0.){
   let air=atmosphereSkyShadow(skyOrigin,ray,f.sun.xyz,f.options.y>0.,shadowLength,cloudTransmission);
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
 if(hasMedium){
   sky=airTransport(sky*medium.transmittance+medium.radiance,1.,origin,origin+ray*medium.entry,0.);
 }
 if(sceneDepthIsBackground(depth)){
   var clearForeground=input.rgb;
   if(hasMedium){clearForeground=airTransport(input.rgb*medium.transmittance+medium.radiance*input.a,input.a,origin,origin+ray*medium.entry,0.);}
   if(f.options.z>0.){return compositeOverlay(vec4<f32>(clamp(clearForeground+sky*(1.-input.a),vec3<f32>(0.),vec3<f32>(65504.)),1.),v.uv,fogDistance);}
   if(hasMedium){
     let transported=airTransport(input.rgb*medium.transmittance+medium.radiance*input.a,input.a,origin,origin+ray*medium.entry,0.);
     return compositeOverlay(vec4(transported,input.a),v.uv,fogDistance);
   }
   return compositeOverlay(input,v.uv,fogDistance);
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
 if((f.aerial.z>0. || f.aerial.w>0. || f.lunar.z>0.) && !degenerate){
   var light=vec3<f32>(0.);
   if(f.aerial.z>0.){light+=atmosphereSunIrradiance(end,normal,f.sun.xyz)*cloudTransmission;}
   if(f.aerial.w>0.){light+=atmosphereSkyIrradiance(end,normal,f.sun.xyz);}
   if(f.lunar.z>0.){
     let radial=safeNormal(end,vec3<f32>(0.,0.,1.));
     let night=1.-smoothstep(-.1,0.,dot(radial,f.sun.xyz));
     if(night>0.){
       var extra=SOLAR*SUN_LUMINANCE*f.lunar.y*max(0.,(1.+dot(normal,radial))*.5);
       if(f.lunar.x>0.){
         // Solar cloud shadows describe the Sun's ray, not the Moon's ray.
         extra+=(atmosphereSunIrradiance(end,normal,f.moon.xyz)+
           atmosphereSkyIrradiance(end,normal,f.moon.xyz))*f.lunar.x;
       }
       light+=extra*night;
     }
   }
   let relit=foreground*(f.geometry.x/PI)*light;
   var mask=1.;if(f.inputs.y>=0.){mask=clamp(sample_lightingMaskImage(v.uv)[u32(f.inputs.y)],0.,1.);}
   foreground=mix(foreground,relit,mask);
 }
 if(hasMedium){
   let endDistance=max(0.,dot(end-origin,ray));
   let entry=min(medium.entry,endDistance);let exit=min(medium.exit,endDistance);
   foreground=airTransport(foreground,input.a,origin+ray*exit,end,shadowLength);
   foreground=foreground*medium.transmittance+medium.radiance*input.a;
   foreground=airTransport(foreground,input.a,origin,origin+ray*entry,0.);
 }else{
   foreground=airTransport(foreground,input.a,origin,end,shadowLength);
 }
 if(f.options.z>0.){return compositeOverlay(vec4<f32>(clamp(foreground+sky*(1.-input.a),vec3<f32>(0.),vec3<f32>(65504.)),1.),v.uv,fogDistance);}
 return compositeOverlay(vec4<f32>(clamp(foreground,vec3<f32>(0.),vec3<f32>(65504.)),input.a),v.uv,fogDistance);
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
