const oceanCausticsWgsl = '''
struct CausticSettings {
 anchor:vec4<f32>,east:vec4<f32>,north:vec4<f32>,up:vec4<f32>,work:vec4<f32>,
 shadowAnchor:vec4<f32>,shadowU:vec4<f32>,shadowV:vec4<f32>,padding:array<vec4<f32>,2>,
};
@group(0) @binding(0) var<uniform> caustic:CausticSettings;
@group(0) @binding(1) var causticShadow:texture_2d<f32>;
@group(0) @binding(2) var causticRaw:texture_2d<f32>;
@group(0) @binding(3) var<storage,read_write> causticPartial:array<vec4<f32>>;
@group(0) @binding(4) var<storage,read_write> causticNormalization:vec4<f32>;
@group(0) @binding(5) var causticOutput:texture_storage_2d<rgba16float,write>;
fn causticFresnel(c:f32)->f32{
 let ior=water.surface.z;let t=sqrt(max(0.,1.-(1.-c*c)/(ior*ior)));
 let rs=(c-ior*t)/max(1e-8,c+ior*t);let rp=(ior*c-t)/max(1e-8,ior*c+t);
 return .5*(rs*rs+rp*rp);
}
fn causticVisibility(p:vec3<f32>)->f32{
 if(caustic.work.z<.5){return 1.;}
 let relative=p+caustic.shadowAnchor.xyz;
 let uv=vec2(dot(relative,caustic.shadowU.xyz),dot(relative,caustic.shadowV.xyz))+vec2(.5);
 if(any(uv<vec2(0.)) || any(uv>=vec2(1.))){return 0.;}
 return clamp(textureLoad(causticShadow,vec2<i32>(uv*vec2<f32>(textureDimensions(causticShadow))),0).r,0.,1.);
}
struct CausticVertex {
 @builtin(position) clip:vec4<f32>,@location(0) surface:vec3<f32>,
 @location(1) normal:vec3<f32>,@location(2) path:f32,
};
@vertex fn vertex(@builtin(vertex_index) index:u32)->CausticVertex{
 let size=u32(caustic.up.w);let cell=index/6u;
 let corners=array<vec2<f32>,6>(vec2(0.,0.),vec2(1.,0.),vec2(1.,1.),vec2(0.,0.),vec2(1.,1.),vec2(0.,1.));
 let uv=(vec2<f32>(f32(cell%size),f32(cell/size))+corners[index%6u])/caustic.up.w;
 let offset=(uv-vec2(.5))*caustic.anchor.w;
 var base=caustic.anchor.xyz+caustic.east.xyz*offset.x+caustic.north.xyz*offset.y;
 // Stable metre-scale projection avoids subtracting Earth-sized float squares.
 for(var i=0u;i<3u;i++){
  let gradient=water.originWeighted.xyz+base*water.inverseRadii.xyz;
  let error=caustic.work.x+2.*dot(water.originWeighted.xyz,base)+dot(base*water.inverseRadii.xyz,base);
  base-=caustic.up.xyz*error/max(1e-5,2.*dot(gradient,caustic.up.xyz));
 }
 let field=waterSurface(base,caustic.anchor.w/caustic.up.w);
 let surface=base+field.offset;let normal=field.normal;
 let direction=refract(-water.sunDirection.xyz,normal,1./water.surface.z);
 let denominator=dot(direction,caustic.up.xyz);
 let path=max(0.,(dot(caustic.anchor.xyz-surface,caustic.up.xyz)-caustic.east.w)/min(-1e-5,denominator));
 let hit=surface+direction*path-caustic.anchor.xyz;
 let projected=vec2(dot(hit,caustic.east.xyz),dot(hit,caustic.north.xyz))/caustic.anchor.w;
 var clip=vec4(projected*2.,0.,1.);
 if(dot(normal,water.sunDirection.xyz)<=0. || denominator>=-1e-5){clip=vec4(4.,4.,0.,1.);}
 return CausticVertex(clip,surface,normal,path);
}
@fragment fn fragment(v:CausticVertex)->@location(0) vec4<f32>{
 let area=cross(dpdy(v.surface),dpdx(v.surface));
 let pixelArea=pow(caustic.anchor.w/caustic.up.w,2.);
 let flux=abs(dot(area,water.sunDirection.xyz))/pixelArea;
 let cosine=max(0.,dot(normalize(v.normal),water.sunDirection.xyz));
 let power=1.-causticFresnel(cosine);
 let attenuation=exp(-(water.absorption.xyz+water.scattering.xyz)*v.path);
 let light=attenuation*(flux*power*causticVisibility(v.surface));
 return vec4(clamp(light,vec3(0.),vec3(65504.)),1.);
}
var<workgroup> causticSums:array<vec4<f32>,256>;
fn reduceCaustic(lane:u32){
 workgroupBarrier();
 for(var stride=128u;stride>0u;stride/=2u){
  if(lane<stride){causticSums[lane]+=causticSums[lane+stride];}
  workgroupBarrier();
 }
}
fn boundedCaustic(pixel:vec2<i32>)->vec3<f32>{
 let incident=max(0.,dot(caustic.up.xyz,water.sunDirection.xyz));
 return clamp(textureLoad(causticRaw,pixel,0).rgb,vec3(0.),vec3(caustic.north.w*incident));
}
@compute @workgroup_size(256) fn partialFlux(@builtin(local_invocation_index) lane:u32,@builtin(workgroup_id) group:vec3<u32>){
 let index=group.x*256u+lane;let size=u32(caustic.up.w);var value=vec3(0.);
 if(index<size*size){value=boundedCaustic(vec2<i32>(i32(index%size),i32(index/size)));}
 causticSums[lane]=vec4(value,0.);reduceCaustic(lane);
 if(lane==0u){causticPartial[group.x]=causticSums[0];}
}
@compute @workgroup_size(256) fn totalFlux(@builtin(local_invocation_index) lane:u32){
 var value=vec4(0.);
 for(var i=lane;i<u32(caustic.work.y);i+=256u){value+=causticPartial[i];}
 causticSums[lane]=value;reduceCaustic(lane);
 if(lane==0u){
  let incident=max(1e-5,dot(caustic.up.xyz,water.sunDirection.xyz));
  causticNormalization=vec4(max(vec3(1.),causticSums[0].rgb/(caustic.up.w*caustic.up.w*incident)),0.);
 }
}
@compute @workgroup_size(8,8) fn resolve(@builtin(global_invocation_id) id:vec3<u32>){
 if(any(id.xy>=vec2<u32>(u32(caustic.up.w)))){return;}
 let pixel=vec2<i32>(id.xy);let factor=boundedCaustic(pixel)/causticNormalization.rgb;
 textureStore(causticOutput,pixel,vec4(factor,1.));
}
''';

const oceanCausticReceiverWgsl = '''
struct ReceiverSettings {
 origin:vec4<f32>,east:vec4<f32>,north:vec4<f32>,up:vec4<f32>,
 sun:vec4<f32>,ambient:vec4<f32>,albedo:vec4<f32>,sunDirection:vec4<f32>,
};
@group(1) @binding(0) var<uniform> receiver:ReceiverSettings;
@group(1) @binding(1) var receivedCaustics:texture_2d<f32>;
struct ReceiverVertex{@builtin(position) clip:vec4<f32>,@location(0) relative:vec3<f32>};
@vertex fn vertex(@location(0) p:vec3<f32>,@location(1) n:vec3<f32>)->ReceiverVertex{
 return ReceiverVertex(mesh.viewProjection*mesh.model*vec4(p,1.),p+receiver.origin.xyz);
}
@fragment fn fragment(v:ReceiverVertex)->@location(0) vec4<f32>{
 let uv=vec2(dot(v.relative,receiver.east.xyz),dot(v.relative,receiver.north.xyz))/receiver.origin.w+vec2(.5);
 // Raster projection uses upward north, while native images have top-left UVs.
 let topUv=vec2(uv.x,1.-uv.y);var irradiance=vec3(0.);
 if(all(topUv>=vec2(0.)) && all(topUv<=vec2(1.)) && abs(dot(v.relative,receiver.up.xyz)+receiver.east.w)<=receiver.north.w){
  let size=vec2<i32>(textureDimensions(receivedCaustics));let p=topUv*vec2<f32>(size)-vec2(.5);
  let i=vec2<i32>(floor(p));let f=fract(p);
  for(var y=0i;y<2i;y++){for(var x=0i;x<2i;x++){
   let weight=select(1.-f.x,f.x,x==1i)*select(1.-f.y,f.y,y==1i);
   irradiance+=weight*textureLoad(receivedCaustics,clamp(i+vec2(x,y),vec2(0),size-vec2(1)),0).rgb;
  }}
 }
 let direct=oceanMediumSun(receiver.up.xyz,receiver.sunDirection.xyz,receiver.sun.rgb);
 let radiance=receiver.albedo.rgb*(receiver.ambient.rgb+direct*irradiance*.31830988618);
 return vec4(clamp(radiance,vec3(0.),vec3(65504.)),1.);
}
''';
