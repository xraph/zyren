const oceanNoInteractionWgsl = '''
fn waterInteraction(p:vec3<f32>)->vec4<f32>{return vec4(0.);}
fn waterInteractionUp()->vec3<f32>{return vec3(0.);}
fn waterInteractionEast()->vec3<f32>{return vec3(0.);}
fn waterInteractionNorth()->vec3<f32>{return vec3(0.);}
fn waterFoamCoverage(p:vec3<f32>,coverage:f32,footprint:f32)->f32{return coverage;}
''';

const oceanInteractionSurfaceWgsl = '''
@group(1) @binding(15) var interactionField:texture_2d<f32>;
fn interactionMapping()->vec4<f32>{
  return textureLoad(interactionField,vec2(0,i32(textureDimensions(interactionField).x)),0);
}
fn waterInteractionUp()->vec3<f32>{return water.interactionUp.xyz;}
fn waterInteractionEast()->vec3<f32>{return water.interactionEast.xyz;}
fn waterInteractionNorth()->vec3<f32>{return water.interactionNorth.xyz;}
fn interactionRead(p:vec2<i32>)->vec4<f32>{
  let n=i32(interactionMapping().w);
  if(any(p<vec2(0))||any(p>=vec2(n))){return vec4(0.);}
  return textureLoad(interactionField,p,0);
}
fn interactionCubic(t:f32)->vec4<f32>{
  let t2=t*t;let t3=t2*t;
  return vec4(-.5*t+t2-.5*t3,1.-2.5*t2+1.5*t3,.5*t+2.*t2-1.5*t3,-.5*t2+.5*t3);
}
fn interactionCubicDerivative(t:f32)->vec4<f32>{
  return vec4(-.5+2.*t-1.5*t*t,-5.*t+4.5*t*t,.5+4.*t-4.5*t*t,-t+1.5*t*t);
}
fn waterInteraction(p:vec3<f32>)->vec4<f32>{
  let delta=p+water.interactionOrigin.xyz;
  let uv=(vec2(dot(delta,water.interactionEast.xyz),dot(delta,water.interactionNorth.xyz))-interactionMapping().xy)/interactionMapping().z+vec2(.5);
  if(any(uv<vec2(0.))||any(uv>vec2(1.))){return vec4(0.);}
  let grid=uv*(interactionMapping().w-1.);let cell=vec2<i32>(floor(grid));let f=fract(grid);
  let wx=interactionCubic(f.x);let wy=interactionCubic(f.y);
  let dx=interactionCubicDerivative(f.x);let dy=interactionCubicDerivative(f.y);
  var h=0.;var slope=vec2(0.);var foam=0.;
  for(var y=0u;y<4u;y++){for(var x=0u;x<4u;x++){
    let value=interactionRead(cell+vec2<i32>(i32(x)-1,i32(y)-1));
    h+=value.x*wx[x]*wy[y];
    slope+=value.x*vec2(dx[x]*wy[y],wx[x]*dy[y]);
    if(x>=1u && x<=2u && y>=1u && y<=2u){
      foam+=value.w*select(1.-f.x,f.x,x==2u)*select(1.-f.y,f.y,y==2u);
    }
  }}
  slope*=(interactionMapping().w-1.)/interactionMapping().z;
  let edge=min(min(grid.x,grid.y),min(interactionMapping().w-1.-grid.x,interactionMapping().w-1.-grid.y));
  return vec4(h,slope,foam*clamp(edge,0.,1.));
}
fn foamHash(p:vec2<i32>)->f32 {
  var h=bitcast<u32>(p.x)*374761393u+bitcast<u32>(p.y)*668265263u;
  h=(h^(h>>13u))*1274126177u;h=h^(h>>16u);
  return f32(h>>8u)/16777216.;
}
fn foamNoise(p:vec2<f32>)->f32 {
  let cell=vec2<i32>(floor(p));let t=fract(p);let f=t*t*(vec2(3.)-2.*t);
  return mix(mix(foamHash(cell),foamHash(cell+vec2(1,0)),f.x),
    mix(foamHash(cell+vec2(0,1)),foamHash(cell+vec2(1,1)),f.x),f.y);
}
fn waterFoamCoverage(p:vec3<f32>,coverage:f32,footprint:f32)->f32 {
  if(coverage<=0.){return 0.;}if(coverage>=1.){return 1.;}
  let delta=p+water.interactionOrigin.xyz;
  let q=vec2(dot(delta,water.interactionEast.xyz),dot(delta,water.interactionNorth.xyz));
  let coarse=foamNoise(q*3.);
  let fine=foamNoise(q*17.+vec2(31.,7.));
  let detail=mix(coarse,.7*coarse+.3*fine,clamp(1.-footprint*17.,0.,1.));
  let width=max(.07,clamp(footprint*3.,0.,.5));
  let broken=smoothstep(detail-width,detail+width,coverage);
  // Unresolved microstructure tends back to mean coverage, avoiding shimmer.
  return mix(broken,coverage,clamp(footprint*3.,0.,1.));
}
''';
