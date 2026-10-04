import 'package:zyren/zyren.dart';

String oceanWaterWgsl({
  required bool deformed,
  required String environmentSource,
  bool boundary = false,
}) =>
    '''
${MeshShaderInterface.wgsl}
${boundary ? '' : MeshShaderInterface.sceneInputs}
${deformed ? MeshShaderInterface.deformation : ''}
$_settings
${boundary ? '' : environmentSource}
$_waves
${boundary ? '' : _optics}
struct WaterVertex {
  @builtin(position) clip:vec4<f32>,
  @location(0) base:vec3<f32>,
  @location(1) relative:vec3<f32>,
};
@vertex fn vertex(@builtin(vertex_index) index:u32,@location(0) p:vec3<f32>,@location(1) n:vec3<f32>)->WaterVertex {
  let base=${deformed ? 'deform_vertex(index,p,n,vec4(1.,0.,0.,1.)).position' : 'p'};
  let fraction=${deformed ? 'bitcast<f32>(deformation_pose[4])' : '0.'};
  let offset=waterVertexOffset(index,base,fraction);
  let relative=(mesh.model*vec4(base+offset,1.)).xyz;
  return WaterVertex(mesh.viewProjection*vec4(relative,1.),base,relative);
}
${boundary ? _boundaryFragment : _fragment}
''';

const _settings = '''
struct WaterSettings {
  originWeighted:vec4<f32>, inverseRadii:vec4<f32>, originKm:vec4<f32>,
  surface:vec4<f32>, grid:vec4<f32>, absorption:vec4<f32>, scattering:vec4<f32>,
  sunDirection:vec4<f32>, sunIrradiance:vec4<f32>, sky:vec4<f32>, ground:vec4<f32>,
  reflection:vec4<f32>, reflectionLimits:vec4<f32>, environment:vec4<f32>,
  active0:vec4<f32>, active1:vec4<f32>, phases:array<vec4<f32>,48>,
};
@group(1) @binding(0) var<uniform> water:WaterSettings;
@group(1) @binding(1) var chart0:texture_2d<f32>;
@group(1) @binding(2) var chart1:texture_2d<f32>;
@group(1) @binding(3) var chart2:texture_2d<f32>;
@group(1) @binding(4) var chart3:texture_2d<f32>;
@group(1) @binding(5) var chart4:texture_2d<f32>;
@group(1) @binding(6) var chart5:texture_2d<f32>;
@group(1) @binding(13) var waterControls:texture_2d<f32>;
fn waterControl(index:u32)->vec4<f32>{
  let width=u32(water.environment.z);
  return textureLoad(waterControls,vec2<i32>(i32(index%width),i32(index/width)),0);
}
fn waveRead(chart:u32,index:u32)->vec4<f32> {
  let width=u32(water.grid.x)*4u;let pixel=vec2<i32>(i32(index%width),i32(index/width));
  switch chart { case 0u:{return textureLoad(chart0,pixel,0);} case 1u:{return textureLoad(chart1,pixel,0);}
    case 2u:{return textureLoad(chart2,pixel,0);} case 3u:{return textureLoad(chart3,pixel,0);}
    case 4u:{return textureLoad(chart4,pixel,0);} default:{return textureLoad(chart5,pixel,0);} }
}
fn chartActive(chart:u32)->bool {
  if(chart<4u){return water.active0[chart]>.5;} return water.active1[chart-4u]>.5;
}
const CHART_N=array<vec3<f32>,6>(vec3(1.,0.,0.),vec3(-1.,0.,0.),vec3(0.,1.,0.),vec3(0.,-1.,0.),vec3(0.,0.,1.),vec3(0.,0.,-1.));
const CHART_U=array<vec3<f32>,6>(vec3(0.,1.,0.),vec3(0.,-1.,0.),vec3(-1.,0.,0.),vec3(1.,0.,0.),vec3(1.,0.,0.),vec3(1.,0.,0.));
const CHART_V=array<vec3<f32>,6>(vec3(0.,0.,1.),vec3(0.,0.,1.),vec3(0.,0.,1.),vec3(0.,0.,1.),vec3(0.,1.,0.),vec3(0.,-1.,0.));
''';

const _waves = '''
struct WaveValue { displacement:vec4<f32>, derivatives:vec4<f32>, moments:vec4<f32> };
fn mixWave(a:WaveValue,b:WaveValue,t:f32)->WaveValue {
  return WaveValue(mix(a.displacement,b.displacement,t),mix(a.derivatives,b.derivatives,t),mix(a.moments,b.moments,t));
}
fn waveLevel(chart:u32,band:u32,uv:vec2<f32>,level:u32)->WaveValue {
  var width=u32(water.grid.x); var offset=band*u32(water.grid.w);
  for(var l=0u;l<level;l++){offset+=width*width; width/=2u;}
  let step=f32(1u<<level);
  // The average of a box lies at its center, not at its first source texel.
  let p=(uv*water.grid.x-vec2(.5*(step-1.)))/step;
  let cell=vec2<i32>(floor(p)); let f=fract(p);
  var d=vec4(0.);var g=vec4(0.);var m=vec4(0.);
  for(var y=0i;y<2i;y++){ for(var x=0i;x<2i;x++){
    let q=((cell+vec2(x,y))%i32(width)+vec2<i32>(i32(width)))%i32(width);
    let at=3u*(offset+u32(q.y)*width+u32(q.x));
    let w=select(1.-f.x,f.x,x==1i)*select(1.-f.y,f.y,y==1i);
    d+=w*waveRead(chart,at);g+=w*waveRead(chart,at+1u);m+=w*waveRead(chart,at+2u);
  }}
  return WaveValue(d,g,m);
}
fn chartWave(chart:u32,p:vec3<f32>,footprint:f32)->WaveValue {
  var value=WaveValue(vec4(0.),vec4(0.),vec4(0.));
  if(!chartActive(chart)){return value;}
  let local=vec2(dot(p,CHART_U[chart]),dot(p,CHART_V[chart]));
  for(var band=0u;band<u32(water.grid.z);band++){
    let phase=water.phases[chart*8u+band];
    let uv=fract((local+phase.xy)/phase.z);
    let lod=clamp(log2(max(1.,footprint*water.grid.x/phase.z)),0.,water.grid.y-1.);
    let low=u32(floor(lod)); let high=min(low+1u,u32(water.grid.y)-1u);
    let v=mixWave(waveLevel(chart,band,uv,low),waveLevel(chart,band,uv,high),fract(lod));
    value.displacement+=v.displacement;value.derivatives+=v.derivatives;
    value.moments.x+=v.moments.x;
    value.moments.y+=max(0.,v.moments.y-dot(v.derivatives.xy,v.derivatives.xy))+phase.w;
  }
  return value;
}
fn waterVertexOffset(index:u32,base:vec3<f32>,fraction:f32)->vec3<f32>{
  if(water.environment.w<.5){return waterSurface(base,water.surface.x).offset;}
  var result=vec3(0.);
  for(var endpoint=0u;endpoint<2u;endpoint++){
    let weight=select(1.-fraction,fraction,endpoint==1u);
    if(weight<=0.){continue;}
    for(var i=0u;i<6u;i++){
      let at=index*24u+endpoint*12u+2u*i;
      let point=waterControl(at);if(point.w==0.){continue;}
      let footprint=waterControl(at+1u).x;
      result+=waterSurface(point.xyz,footprint).offset*(weight*point.w);
    }
  }
  return result;
}
struct WaterSurface {offset:vec3<f32>,normal:vec3<f32>,variance:f32};
fn waterSurface(p:vec3<f32>,footprint:f32)->WaterSurface {
  let weighted=water.originWeighted.xyz+p*water.inverseRadii.xyz;
  let n=normalize(weighted); let horizontal=vec3(-n.y,n.x,0.);
  var east=vec3(0.,1.,0.);if(dot(horizontal,horizontal)>1e-12){east=normalize(horizontal);}
  let north=cross(n,east);
  let ae=east*water.inverseRadii.xyz;let an=north*water.inverseRadii.xyz;
  let ne=(ae-n*dot(n,ae))/length(weighted);let nn=(an-n*dot(n,an))/length(weighted);
  var weights:array<vec3<f32>,6>;var sum=vec3(0.);
  for(var chart=0u;chart<6u;chart++){
    let a=max(0.,dot(n,CHART_N[chart])-.25);
    let w=vec3(a*a*a*a,4.*a*a*a*dot(CHART_N[chart],ne),4.*a*a*a*dot(CHART_N[chart],nn));
    weights[chart]=w;sum+=w;
  }
  var h=water.originWeighted.w;var he=0.;var hn=0.;var v=vec3(0.);var ve=vec3(0.);var vn=vec3(0.);var variance=0.;
  for(var chart=0u;chart<6u;chart++){
    if(weights[chart].x==0.){continue;}
    let w=weights[chart].x/sum.x;
    let dw=(weights[chart].yz*sum.x-weights[chart].x*sum.yz)/(sum.x*sum.x);
    let f=chartWave(chart,p,footprint);let u=CHART_U[chart];let z=CHART_V[chart];
    let ue=dot(east,u);let un=dot(north,u);let ze=dot(east,z);let zn=dot(north,z);
    let local=u*f.displacement.x+z*f.displacement.z;
    let de=u*(f.derivatives.z*ue+f.moments.x*ze)+z*(f.moments.x*ue+f.derivatives.w*ze);
    let dn=u*(f.derivatives.z*un+f.moments.x*zn)+z*(f.moments.x*un+f.derivatives.w*zn);
    h+=w*f.displacement.y;he+=dw.x*f.displacement.y+w*dot(f.derivatives.xy,vec2(ue,ze));
    hn+=dw.y*f.displacement.y+w*dot(f.derivatives.xy,vec2(un,zn));
    v+=w*local;ve+=dw.x*local+w*de;vn+=dw.y*local+w*dn;variance+=w*w*f.moments.y;
  }
  let projected=dot(n,v);
  let e=east+ne*h+n*he+ve-ne*projected-n*(dot(ne,v)+dot(n,ve));
  let t=north+nn*h+n*hn+vn-nn*projected-n*(dot(nn,v)+dot(n,vn));
  return WaterSurface(n*h+v-n*projected,normalize(cross(e,t)),variance);
}
''';

const _optics = '''
fn waterFresnel(c:f32,incident:f32,transmitted:f32)->f32 {
  if(incident==transmitted){return 0.;}
  let eta=incident/transmitted; let s=eta*eta*max(0.,1.-c*c);
  if(s>=1. || c<=0.){return 1.;}
  let t=sqrt(1.-s);
  let rs=(incident*c-transmitted*t)/(incident*c+transmitted*t);
  let rp=(transmitted*c-incident*t)/(transmitted*c+incident*t);
  return .5*(rs*rs+rp*rp);
}
fn waterSegment(behind:vec3<f32>,incident:vec3<f32>,distance:f32)->vec3<f32> {
  let extinction=water.absorption.xyz+water.scattering.xyz;
  let trans=exp(-extinction*distance);
  return behind*trans+incident*water.scattering.xyz/max(extinction,vec3(1e-20))*(vec3(1.)-trans);
}
fn projectWater(p:vec3<f32>)->vec3<f32> {
  let clip=mesh.viewProjection*vec4(p,1.);
  if(clip.w<=1e-6){return vec3(-1.);}
  let ndc=clip.xyz/clip.w;
  return vec3((ndc.x*.5+.5)*meshScene.viewport.x,(.5-ndc.y*.5)*meshScene.viewport.y,ndc.z);
}
fn waterOnScreen(p:vec3<f32>)->bool {
  return p.z>=0. && p.z<=1. && p.x>=0. && p.y>=0. && p.x<meshScene.viewport.x && p.y<meshScene.viewport.y;
}
struct WaterRayHit {color:vec3<f32>,confidence:f32,distance:f32};
fn waterScreenReflection(start:vec3<f32>,ray:vec3<f32>,viewRay:vec3<f32>,roughness:f32)->WaterRayHit {
  let steps=u32(max(0.,min(water.reflection.y,floor(water.reflectionLimits.x*(water.reflection.y+5.)/(meshScene.viewport.x*meshScene.viewport.y))-5.)));
  var previous=0.;var previousDelta=-1e6;
  for(var i=0u;i<steps;i++){
    let fraction=f32(i+1u)/f32(steps);let distance=water.reflection.z*fraction*fraction;
    let point=start+ray*distance;let pixel=projectWater(point);
    if(!waterOnScreen(pixel)){break;}
    let depth=meshSceneDepth(pixel.xy);
    if(!meshSceneHasSurface(depth)){previous=distance;previousDelta=-1e6;continue;}
    let observed=meshScenePosition(pixel.xy,depth);
    let delta=dot(point-observed,viewRay);
    if(delta>=0. && previousDelta<0.){
      var low=previous;var high=distance;var hitPixel=pixel;var hitPoint=observed;
      // Refinement consumes five additional probes, included in diagnostics.
      for(var refine=0u;refine<5u;refine++){
        let mid=.5*(low+high);let q=start+ray*mid;let uv=projectWater(q);
        if(!waterOnScreen(uv)){break;}
        let d=meshSceneDepth(uv.xy);
        if(!meshSceneHasSurface(d)){low=mid;continue;}
        let scenePoint=meshScenePosition(uv.xy,d);
        if(dot(q-scenePoint,viewRay)>0.){high=mid;hitPixel=uv;hitPoint=scenePoint;}else{low=mid;}
      }
      let error=length(start+ray*high-hitPoint);
      let uv=hitPixel.xy*meshScene.viewport.zw;
      let edge=min(min(uv.x,uv.y),min(1.-uv.x,1.-uv.y));
      let confidence=clamp(edge/water.reflectionLimits.y,0.,1.)*clamp(1.-error/water.reflection.w,0.,1.)*(1.-roughness*roughness);
      if(dot(hitPoint-start,ray)>.02 && confidence>0.){
        return WaterRayHit(meshSceneColor(hitPixel.xy).rgb,confidence,high);
      }
      return WaterRayHit(vec3(0.),0.,0.);
    }
    previous=distance;previousDelta=delta;
  }
  return WaterRayHit(vec3(0.),0.,0.);
}
fn waterSun(n:vec3<f32>,v:vec3<f32>,sun:vec3<f32>,irradiance:vec3<f32>,roughness:f32)->vec3<f32> {
  let nl=max(0.,dot(n,sun));let nv=max(0.,dot(n,v));if(nl<=0. || nv<=0.){return vec3(0.);}
  let halfSum=v+sun;if(dot(halfSum,halfSum)<1e-12){return vec3(0.);}
  let h=normalize(halfSum);let nh=max(0.,dot(n,h));let vh=max(0.,dot(v,h));
  let a=max(.002025,roughness*roughness);let a2=a*a;
  let tangent=cross(n,h);let denom=dot(tangent,tangent)+a2*nh*nh;
  let d=a2/(3.14159265359*denom*denom);
  let visibility=.5/max(nl*sqrt(a2+(1.-a2)*nv*nv)+nv*sqrt(a2+(1.-a2)*nl*nl),1e-12);
  return irradiance*(nl*d*visibility*waterFresnel(vh,1.,water.surface.z));
}
''';

const _fragment = '''
@fragment fn fragment(input:WaterVertex,@builtin(front_facing) front:bool)->@location(0) vec4<f32> {
  let footprint=max(length(dpdx(input.base)),length(dpdy(input.base)));
  let detail=waterSurface(input.base,footprint);
  var n=normalize((mesh.normalMatrix*vec4(detail.normal,0.)).xyz);
  let reversed=meshScene.depthInfo.y>.5;
  let nearPoint=meshScenePosition(input.clip.xy,select(.001,.999,reversed));
  let farPoint=meshScenePosition(input.clip.xy,select(.999,.001,reversed));
  let viewRay=normalize(farPoint-nearPoint);let v=-viewRay;
  if(dot(n,v)<0.){n=-n;}
  let normalDx=dpdx(n);let normalDy=dpdy(n);
  let pixelVariance=.5*(dot(normalDx,normalDx)+dot(normalDy,normalDy));
  let roughness=sqrt(sqrt(min(1.,pow(water.surface.w,4.)+max(0.,detail.variance)+min(.25,pixelVariance))));
  let incoming=select(1.,water.surface.z,!front);let outgoing=select(water.surface.z,1.,!front);
  let fresnel=waterFresnel(clamp(dot(n,v),0.,1.),incoming,outgoing);
  let sun=normalize((mesh.normalMatrix*vec4(water.sunDirection.xyz,0.)).xyz);
  let light=waterIncident(input.base,detail.normal);
  var reflected=vec3(0.);var confidence=0.;
  if(water.reflection.x>.5){
    let direction=reflect(viewRay,n);
    let localDirection=normalize(transpose(mat3x3(mesh.normalMatrix[0].xyz,mesh.normalMatrix[1].xyz,mesh.normalMatrix[2].xyz))*direction);
    reflected=select(waterSegment(vec3(0.),light,water.surface.y),waterEnvironment(input.base,localDirection,roughness),front);
    if(water.reflection.x>1.5){
      let hit=waterScreenReflection(input.relative+n*.02,direction,viewRay,roughness);
      let hitColor=select(waterSegment(hit.color,light,hit.distance),hit.color,front);
      reflected=mix(reflected,hitColor,hit.confidence);confidence=hit.confidence;
    }
  }
  var distance=water.surface.y;var behind=vec3(0.);
  let transmitted=refract(viewRay,n,incoming/outgoing);
  if(fresnel<1. && dot(transmitted,transmitted)>.5){
    if(!front){
      let localTransmission=normalize(transpose(mat3x3(mesh.normalMatrix[0].xyz,mesh.normalMatrix[1].xyz,mesh.normalMatrix[2].xyz))*transmitted);
      behind=waterEnvironment(input.base,localTransmission,roughness);
    }
    let firstDepth=meshSceneDepth(input.clip.xy);
    if(meshSceneHasSurface(firstDepth)){
      let firstPoint=meshScenePosition(input.clip.xy,firstDepth);
      if(dot(firstPoint-input.relative,n)<-.001){
        distance=clamp(dot(firstPoint-input.relative,n)/min(-1e-5,dot(transmitted,n)),0.,water.surface.y);
        behind=meshSceneColor(input.clip.xy).rgb;
        for(var iteration=0u;iteration<2u;iteration++){
          let pixel=projectWater(input.relative+transmitted*distance);
          if(!waterOnScreen(pixel)){break;}
          let depth=meshSceneDepth(pixel.xy);if(!meshSceneHasSurface(depth)){break;}
          let point=meshScenePosition(pixel.xy,depth);
          if(dot(point-input.relative,n)>=-.001 || dot(point-input.relative,v)>=-.001){break;}
          distance=clamp(dot(point-input.relative,n)/min(-1e-5,dot(transmitted,n)),0.,water.surface.y);
          behind=meshSceneColor(pixel.xy).rgb;
        }
      }
    }
  }
  let transmission=select(behind,waterSegment(behind,light,distance),front);
  var color=reflected*fresnel+transmission*(1.-fresnel);
  if(front && water.reflection.x>.5){color+=waterSun(n,v,sun,waterDirect(input.base),roughness);}
  if(water.reflectionLimits.z==1.){color=n*.5+vec3(.5);}
  if(water.reflectionLimits.z==2.){color=vec3(distance/water.surface.y);}
  if(water.reflectionLimits.z==3.){color=vec3(confidence);}
  return vec4(max(color,vec3(0.)),1.);
}
''';

// Distances are camera-forward metres. Splitting into a multiple of 32 and a
// remainder keeps RGBA16F quantization below 8 mm out to 60 km.
const _boundaryFragment = '''
@group(1) @binding(14) var<uniform> boundaryForward:vec4<f32>;
@fragment fn fragment(input:WaterVertex,@builtin(front_facing) front:bool)->@location(0) vec4<f32> {
  let distance=dot(input.relative,boundaryForward.xyz);
  if(distance<0. || distance>60000.){discard;}
  let coarse=floor(distance/32.);
  return vec4(coarse,distance-coarse*32.,select(2.,1.,front),1.);
}
''';
