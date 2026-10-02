import 'package:zyren/zyren.dart';

const _common =
    '''
${PostProcessDescriptor.interfaceWgsl}
fn loadClamped(image:texture_2d<f32>,p:vec2<i32>)->vec4<f32>{return textureLoad(image,clamp(p,vec2<i32>(0),vec2<i32>(textureDimensions(image))-1),0);}
fn sampleGl(image:texture_2d<f32>,uv:vec2<f32>)->vec4<f32>{
 let raw=vec2<f32>(uv.x,1.-uv.y)*vec2<f32>(textureDimensions(image))-.5;
 let p=select(raw,round(raw),abs(raw-round(raw))<vec2<f32>(.0001));
 let b=vec2<i32>(floor(p));let f=fract(p);
 return mix(mix(loadClamped(image,b),loadClamped(image,b+vec2<i32>(1,0)),f.x),mix(loadClamped(image,b+vec2<i32>(0,1)),loadClamped(image,b+vec2<i32>(1)),f.x),f.y);
}
fn decode(c:vec4<f32>)->vec4<f32>{let v=c.rgb/max(c.a,1e-6);return vec4<f32>(select(v/12.92,pow(max((v+.055)/1.055,vec3<f32>(0.)),vec3<f32>(2.4)),v>vec3<f32>(.04045))*c.a,c.a);}
fn encode(c:vec4<f32>)->vec4<f32>{let v=c.rgb/max(c.a,1e-6);return vec4<f32>(select(v*12.92,1.055*pow(max(v,vec3<f32>(0.)),vec3<f32>(1./2.4))-.055,v>vec3<f32>(.0031308))*c.a,c.a);}
fn color(uv:vec2<f32>)->vec4<f32>{
 let p=vec2<f32>(uv.x,1.-uv.y)*vec2<f32>(textureDimensions(sceneColor))-.5;
 let b=vec2<i32>(floor(p));let f=fract(p);
 return mix(mix(decode(loadClamped(sceneColor,b)),decode(loadClamped(sceneColor,b+vec2<i32>(1,0))),f.x),mix(decode(loadClamped(sceneColor,b+vec2<i32>(0,1))),decode(loadClamped(sceneColor,b+vec2<i32>(1))),f.x),f.y);
}
''';

String smaaEdgesWgsl(double threshold) =>
    '''
$_common
fn difference(a:vec3<f32>,b:vec3<f32>)->f32{let d=abs(a-b);return max(max(d.r,d.g),d.b);}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let uv=vec2<f32>(v.uv.x,1.-v.uv.y);let d=1./screen.viewport.xy;
 let c=color(uv).rgb;
 let delta=vec2<f32>(difference(c,color(uv-vec2<f32>(d.x,0.)).rgb),difference(c,color(uv-vec2<f32>(0.,d.y)).rgb));
 var edges=step(vec2<f32>($threshold),delta);
 if(dot(edges,vec2<f32>(1.))==0.){return vec4<f32>(0.,0.,0.,1.);}
 let other=vec2<f32>(difference(c,color(uv+vec2<f32>(d.x,0.)).rgb),difference(c,color(uv+vec2<f32>(0.,d.y)).rgb));
 let distant=vec2<f32>(difference(c,color(uv-vec2<f32>(d.x*2.,0.)).rgb),difference(c,color(uv-vec2<f32>(0.,d.y*2.)).rgb));
 let maximum=max(max(delta,other),distant);
 edges*=step(vec2<f32>(max(maximum.x,maximum.y)),2.*delta);
 return vec4<f32>(edges,0.,1.);
}
''';

String smaaWeightsWgsl(int steps, int diagonal) =>
    '''
$_common
@group(1) @binding(0) var edgeImage:texture_2d<f32>;
@group(1) @binding(1) var areaImage:texture_2d<f32>;
@group(1) @binding(2) var searchImage:texture_2d<f32>;
fn texel()->vec2<f32>{return 1./vec2<f32>(textureDimensions(edgeImage));}
fn edge(uv:vec2<f32>)->vec2<f32>{return sampleGl(edgeImage,uv).rg;}
fn edgeOffset(uv:vec2<f32>,offset:vec2<f32>)->vec2<f32>{return edge(uv+offset*texel());}
fn areaSample(uv:vec2<f32>)->vec2<f32>{return sampleGl(areaImage,vec2<f32>(uv.x,1.-uv.y)).rg;}
fn sourceRound(v:vec2<f32>)->vec2<f32>{return floor(v+.5);}
fn searchLength(e:vec2<f32>,offset:f32)->f32{
 let scale=(vec2<f32>(66.,33.)*vec2<f32>(.5,-1.)+vec2<f32>(-1.,1.))/vec2<f32>(64.,16.);
 let bias=(vec2<f32>(66.,33.)*vec2<f32>(offset,1.)+vec2<f32>(.5,-.5))/vec2<f32>(64.,16.);
 let uv=scale*e+bias;return loadClamped(searchImage,vec2<i32>(floor(vec2<f32>(uv.x,1.-uv.y)*vec2<f32>(64.,16.)))).r;
}
fn search(start:vec2<f32>,end:f32,axis:u32,direction:f32)->f32{
 var uv=start;var e=select(vec2<f32>(0.,1.),vec2<f32>(1.,0.),axis==1u);
 for(var i=0;i<$steps;i++){
  if(!((uv[axis]-end)*direction<0.&&e[1u-axis]>.8281&&e[axis]==0.)){break;}
  e=edge(uv);uv[axis]+=direction*2.*texel()[axis];
 }
 let pair=select(e,e.gr,axis==1u);
 let offset=3.25-(255./127.)*searchLength(pair,select(0.,.5,direction>0.));
 return uv[axis]-direction*texel()[axis]*offset;
}
fn area(distance:vec2<f32>,e1:f32,e2:f32)->vec2<f32>{
 return areaSample((16.*sourceRound(4.*vec2<f32>(e1,e2))+distance+.5)/vec2<f32>(160.,560.));
}
struct DiagSearch { span:vec2<f32>, edge:vec2<f32> };
fn decodeDiag(e:vec2<f32>)->vec2<f32>{return sourceRound(vec2<f32>(e.r*abs(5.*e.r-3.75),e.g));}
fn searchDiag(start:vec2<f32>,direction:vec2<f32>,second:bool)->DiagSearch{
 var uv=start;var distance=-1.;var average=1.;var e=vec2<f32>(0.);
 if(second){uv.x+=.25*texel().x;}
 for(var i=0;i<$steps;i++){
  if(!(distance<f32(${diagonal - 1})&&average>.9)){break;}
  uv+=texel()*direction;distance+=1.;e=edge(uv);
  if(second){e=decodeDiag(e);}average=dot(e,vec2<f32>(.5));
 }
 return DiagSearch(vec2<f32>(distance,average),e);
}
fn areaDiag(distance:vec2<f32>,e:vec2<f32>)->vec2<f32>{
 return areaSample((20.*e+distance+.5)/vec2<f32>(160.,560.)+vec2<f32>(.5,0.));
}
fn diagonalWeights(uv:vec2<f32>,e:vec2<f32>)->vec2<f32>{
 var d=vec4<f32>(0.);var weights=vec2<f32>(0.);
 if(e.r>0.){let s=searchDiag(uv,vec2<f32>(-1.,1.),false);d.x=s.span.x+select(0.,1.,s.edge.y>.9);d.z=s.span.y;}
 let s=searchDiag(uv,vec2<f32>(1.,-1.),false);d.y=s.span.x;d.w=s.span.y;
 if(d.x+d.y>2.){
  let coords=vec4<f32>(-d.x+.25,d.x,d.y,-d.y-.25)*texel().xyxy+uv.xyxy;
  let a=decodeDiag(edgeOffset(coords.xy,vec2<f32>(-1.,0.)));
  let b=decodeDiag(edgeOffset(coords.zw,vec2<f32>(1.,0.)));
  let cc=select(2.*vec2<f32>(a.y,b.y)+vec2<f32>(a.x,b.x),vec2<f32>(0.),d.zw>=vec2<f32>(.9));
  weights+=areaDiag(d.xy,cc);
 }
 let s2=searchDiag(uv,vec2<f32>(-1.,-1.),true);d.x=s2.span.x;d.z=s2.span.y;
 if(edgeOffset(uv,vec2<f32>(1.,0.)).r>0.){let s3=searchDiag(uv,vec2<f32>(1.),true);d.y=s3.span.x+select(0.,1.,s3.edge.y>.9);d.w=s3.span.y;}else{d.y=0.;d.w=0.;}
 if(d.x+d.y>2.){
  let coords=vec4<f32>(-d.x,-d.x,d.y,d.y)*texel().xyxy+uv.xyxy;
  let c=vec4<f32>(edgeOffset(coords.xy,vec2<f32>(-1.,0.)).g,edgeOffset(coords.xy,vec2<f32>(0.,-1.)).r,edgeOffset(coords.zw,vec2<f32>(1.,0.)).gr);
  let cc=select(2.*c.xz+c.yw,vec2<f32>(0.),d.zw>=vec2<f32>(.9));
  weights+=areaDiag(d.xy,cc).gr;
 }
 return weights;
}
fn corner(weights:vec2<f32>,coords:vec4<f32>,distance:vec2<f32>,vertical:bool)->vec2<f32>{
 let lr=step(distance.xy,distance.yx);let rounding=.75*lr/(lr.x+lr.y);
 var factor=vec2<f32>(1.);
 if(vertical){
  factor.x-=rounding.x*edgeOffset(coords.xy,vec2<f32>(1.,0.)).g+rounding.y*edgeOffset(coords.zw,vec2<f32>(1.,1.)).g;
  factor.y-=rounding.x*edgeOffset(coords.xy,vec2<f32>(-2.,0.)).g+rounding.y*edgeOffset(coords.zw,vec2<f32>(-2.,1.)).g;
 }else{
  factor.x-=rounding.x*edgeOffset(coords.xy,vec2<f32>(0.,1.)).r+rounding.y*edgeOffset(coords.zw,vec2<f32>(1.,1.)).r;
  factor.y-=rounding.x*edgeOffset(coords.xy,vec2<f32>(0.,-2.)).r+rounding.y*edgeOffset(coords.zw,vec2<f32>(1.,-2.)).r;
 }
 return weights*clamp(factor,vec2<f32>(0.),vec2<f32>(1.));
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let uv=vec2<f32>(v.uv.x,1.-v.uv.y);let t=texel();let resolution=1./t;
 let off0=uv.xyxy+t.xyxy*vec4<f32>(-.25,-.125,1.25,-.125);
 let off1=uv.xyxy+t.xyxy*vec4<f32>(-.125,-.25,-.125,1.25);
 let off2=vec4<f32>(off0.xz,off1.yw)+vec4<f32>(-2.,2.,-2.,2.)*t.xxyy*f32($steps);
 var weights=vec4<f32>(0.);var e=textureLoad(edgeImage,vec2<i32>(v.position.xy),0).rg;
 if(e.g>0.){
  var horizontal=vec2<f32>(0.);
  ${diagonal > 0 ? 'horizontal=diagonalWeights(uv,e);' : ''}
  if(horizontal.r == -horizontal.g){
   let left=search(off0.xy,off2.x,0u,-1.);let right=search(off0.zw,off2.y,0u,1.);
   let distance=sourceRound(resolution.xx*vec2<f32>(left,right)-(uv*resolution).xx);
   let e1=edge(vec2<f32>(left,off1.y)).r;let e2=edgeOffset(vec2<f32>(right,off1.y),vec2<f32>(1.,0.)).r;
   horizontal=area(sqrt(abs(distance)),e1,e2);
   ${diagonal > 0 ? 'horizontal=corner(horizontal,vec4<f32>(left,uv.y,right,uv.y),distance,false);' : ''}
  }else{e.r=0.;}
  weights.r=horizontal.r;weights.g=horizontal.g;
 }
 if(e.r>0.){
  let up=search(off1.xy,off2.z,1u,-1.);let down=search(off1.zw,off2.w,1u,1.);
  let distance=sourceRound(resolution.yy*vec2<f32>(up,down)-(uv*resolution).yy);
  let e1=edge(vec2<f32>(off0.x,up)).g;let e2=edgeOffset(vec2<f32>(off0.x,down),vec2<f32>(0.,1.)).g;
  var vertical=area(sqrt(abs(distance)),e1,e2);
  ${diagonal > 0 ? 'vertical=corner(vertical,vec4<f32>(uv.x,up,uv.x,down),distance,true);' : ''}
  weights.b=vertical.x;weights.a=vertical.y;
 }
 return floor(weights*255.+.5)/255.;
}
''';

const smaaBlendWgsl =
    '''
$_common
@group(1) @binding(0) var weightImage:texture_2d<f32>;
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{
 let uv=vec2<f32>(v.uv.x,1.-v.uv.y);let t=1./vec2<f32>(textureDimensions(weightImage));
 let center=sampleGl(weightImage,uv);
 let a=vec4<f32>(sampleGl(weightImage,uv+vec2<f32>(t.x,0.)).a,sampleGl(weightImage,uv+vec2<f32>(0.,t.y)).g,center.b,center.r);
 if(dot(a,vec4<f32>(1.))<1e-5){return textureLoad(sceneColor,vec2<i32>(v.position.xy),0);}
 let horizontal=max(a.x,a.z)>max(a.y,a.w);
 let offset=select(vec4<f32>(0.,a.y,0.,a.w),vec4<f32>(a.x,0.,a.z,0.),horizontal);
 var weight=select(a.yw,a.xz,horizontal);weight/=dot(weight,vec2<f32>(1.));
 let coords=offset*vec4<f32>(t,-t)+uv.xyxy;
 return encode(weight.x*color(coords.xy)+weight.y*color(coords.zw));
}
''';
