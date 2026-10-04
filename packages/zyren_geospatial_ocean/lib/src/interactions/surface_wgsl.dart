const oceanNoInteractionWgsl = '''
fn waterInteraction(p:vec3<f32>)->vec4<f32>{return vec4(0.);}
fn waterInteractionUp()->vec3<f32>{return vec3(0.);}
fn waterInteractionEast()->vec3<f32>{return vec3(0.);}
fn waterInteractionNorth()->vec3<f32>{return vec3(0.);}
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
fn waterInteraction(p:vec3<f32>)->vec4<f32>{
  let delta=p+water.interactionOrigin.xyz;
  let uv=(vec2(dot(delta,water.interactionEast.xyz),dot(delta,water.interactionNorth.xyz))-interactionMapping().xy)/interactionMapping().z+vec2(.5);
  if(any(uv<vec2(0.))||any(uv>vec2(1.))){return vec4(0.);}
  let grid=uv*(interactionMapping().w-1.);let cell=vec2<i32>(floor(grid));let f=fract(grid);
  let a=interactionRead(cell);let b=interactionRead(cell+vec2(1,0));
  let c=interactionRead(cell+vec2(0,1));let d=interactionRead(cell+vec2(1,1));
  let value=mix(mix(a,b,f.x),mix(c,d,f.x),f.y);
  // Geometric normals use the derivative of the interpolated height itself.
  let scale=(interactionMapping().w-1.)/interactionMapping().z;
  let slope=vec2(mix(b.x-a.x,d.x-c.x,f.y),mix(c.x-a.x,d.x-b.x,f.x))*scale;
  let edge=min(min(grid.x,grid.y),min(interactionMapping().w-1.-grid.x,interactionMapping().w-1.-grid.y));
  return vec4(value.x,slope,value.w*clamp(edge,0.,1.));
}
''';
