String oceanUnderwaterWgsl({bool transport = false}) =>
    '''
${transport ? '@group(1) @binding(3) var mediumOutput:texture_storage_2d<rgba16float,write>;' : ''}
struct Underwater {
 camera:vec4<f32>, forward:vec4<f32>, absorption:vec4<f32>, scattering:vec4<f32>,
 sky:vec4<f32>, sun:vec4<f32>, direct:vec4<f32>, up:vec4<f32>,
 shadowOrigin:vec4<f32>, shadowU:vec4<f32>, shadowV:vec4<f32>,
 planes:array<vec4<f32>,6>,sunEcef:vec4<f32>,upEcef:vec4<f32>,environment:vec4<f32>,padding:array<vec4<f32>,8>,
};
@group(1) @binding(0) var<uniform> underwater:Underwater;
@group(1) @binding(1) var waterBoundary:texture_2d<f32>;
@group(1) @binding(2) var waterShadow:texture_2d<f32>;
fn boundaryAt(uv:vec2<f32>)->vec4<f32>{
 let size=textureDimensions(waterBoundary);let pixel=clamp(vec2<i32>(uv*vec2<f32>(size)),vec2(0),vec2<i32>(size)-vec2(1));
 return textureLoad(waterBoundary,pixel,0);
}
fn shadowAt(point:vec3<f32>)->f32{
 if(underwater.shadowOrigin.w<.5){return underwater.sun.w;}
 let p=point+underwater.shadowOrigin.xyz;
 let uv=vec2(dot(p,underwater.shadowU.xyz),dot(p,underwater.shadowV.xyz))+vec2(.5);
 if(any(uv<vec2(0.)) || any(uv>=vec2(1.))){return 0.;}
 let size=textureDimensions(waterShadow);
 return clamp(textureLoad(waterShadow,vec2<i32>(uv*vec2<f32>(size)),0).r,0.,1.);
}
fn underwaterClip(origin:vec3<f32>,ray:vec3<f32>,maximum:f32)->vec2<f32>{
 var low=0.;var high=maximum;
 for(var i=0u;i<u32(underwater.camera.w);i++){
  let plane=underwater.planes[i];let den=dot(plane.xyz,ray);let num=plane.w-dot(plane.xyz,origin+underwater.camera.xyz);
  if(abs(den)<1e-8){if(num<0.){return vec2(0.);}}
  else if(den>0.){high=min(high,num/den);}else{low=max(low,num/den);}
  if(high<=low){return vec2(0.);}
 }
 return vec2(low,high);
}
fn underwaterResult(input:vec4<f32>,transmission:vec3<f32>,scattering:vec3<f32>,segment:vec2<f32>,pixel:vec2<i32>)->vec4<f32>{
 ${transport ? r"let halfWidth=i32(textureDimensions(mediumOutput).x)/2; textureStore(mediumOutput,pixel,vec4(transmission,segment.x)); textureStore(mediumOutput,pixel+vec2(halfWidth,0),vec4(scattering,segment.y)); return input;" : 'return vec4(clamp(input.rgb*transmission+scattering*input.a,vec3(0.),vec3(65504.)),input.a);'}
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let pixel=vec2<i32>(v.position.xy);let input=textureLoad(sceneColor,pixel,0);
 let depth=textureLoad(sceneDepth,pixel,0);let middle=scenePosition(v.uv,.5);
 var origin=vec3(0.);var ray=normalize(middle);
 if(underwater.forward.w>=0.){
  ray=underwater.forward.xyz;
  origin=scenePosition(v.uv,sceneNearDepth())-ray*underwater.forward.w;
 }
 var maximum=60000.;
 if(!sceneDepthIsBackground(depth)){maximum=min(maximum,max(0.,dot(scenePosition(v.uv,depth)-origin,ray)));}
 let boundary=boundaryAt(v.uv);
 if(boundary.a>.5){
  // An entering face has no water between the camera and that first interface.
  if(boundary.b<1.5){return underwaterResult(input,vec3(1.),vec3(0.),vec2(0.),pixel);}
  maximum=min(maximum,(boundary.r*32.+boundary.g)/max(1e-5,dot(ray,underwater.forward.xyz)));
 }else if(underwater.up.w+dot(origin,underwater.up.xyz)>=0.){return underwaterResult(input,vec3(1.),vec3(0.),vec2(0.),pixel);}
 let segment=underwaterClip(origin,ray,maximum);let distance=min(underwater.absorption.w,max(0.,segment.y-segment.x));
 if(distance<=0.){return underwaterResult(input,vec3(1.),vec3(0.),vec2(0.),pixel);}
 let extinction=underwater.absorption.xyz+underwater.scattering.xyz;
 let transmission=exp(-extinction*distance);
 let albedo=underwater.scattering.xyz/max(extinction,vec3(1e-20));
 let sky=oceanMediumSky(underwater.upEcef.xyz,underwater.sunEcef.xyz,underwater.sky.xyz,underwater.environment.xy);
 var scattering=sky*albedo*(vec3(1.)-transmission);
 let steps=u32(underwater.sky.w);
 if(steps>0u){
  let incidentCosine=max(0.,dot(underwater.up.xyz,underwater.sun.xyz));
  let eta=1./underwater.direct.w;
  let refractedCosine=sqrt(max(0.,1.-eta*eta*(1.-incidentCosine*incidentCosine)));
  let rs=(incidentCosine-underwater.direct.w*refractedCosine)/max(1e-8,incidentCosine+underwater.direct.w*refractedCosine);
  let rp=(underwater.direct.w*incidentCosine-refractedCosine)/max(1e-8,underwater.direct.w*incidentCosine+refractedCosine);
  let power=(1.-.5*(rs*rs+rp*rp))*select(0.,1.,incidentCosine>0.);
  var sunlight=vec3(0.);
  for(var i=0u;i<steps;i++){
   let t=segment.x+(f32(i)+.5)*distance/f32(steps);let p=origin+ray*t;
   // Local surface-depth approximation for the incoming light path. Optical
   // view clipping itself uses the actual displaced surface capture.
   let lightDepth=max(0.,-(underwater.up.w+dot(p,underwater.up.xyz)))/max(.05,refractedCosine);
   let near=(f32(i))*distance/f32(steps);let far=(f32(i)+1.)*distance/f32(steps);
   let viewWeight=exp(-extinction*near)-exp(-extinction*far);
   sunlight+=exp(-extinction*lightDepth)*shadowAt(p)*viewWeight;
  }
  let direct=oceanMediumSun(underwater.upEcef.xyz,underwater.sunEcef.xyz,underwater.direct.xyz);
  scattering+=direct*sunlight*albedo*(power*.07957747155);
 }
 // Scene input is premultiplied. Transparent background stays transparent.
 return underwaterResult(input,transmission,scattering,segment,pixel);
}
''';
