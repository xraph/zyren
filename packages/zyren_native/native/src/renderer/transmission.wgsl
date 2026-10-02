@group(0) @binding(13) var opaque_color: texture_2d<f32>;
@group(0) @binding(14) var opaque_depth: texture_depth_2d;

// Bilinear associated radiance. Depth rejection prevents a foreground surface
// from being pulled into a refracted background sample.
fn transmission_sample(uv:vec2<f32>, surface_depth:f32) -> vec4<f32> {
    let size=vec2<i32>(textureDimensions(opaque_color));
    let pixel=uv*vec2<f32>(size)-vec2(.5);
    let low=vec2<i32>(floor(pixel)); let fraction=fract(pixel);
    var color=vec4(0.); var total=0.;
    for (var y=0;y<2;y++) { for(var x=0;x<2;x++) {
        let p=low+vec2(x,y);
        if (any(p<vec2(0)) || any(p>=size)) {continue;}
        let depth = textureLoad(opaque_depth,p,0);
        let foreground = select(depth + .00001 < surface_depth, depth - .00001 > surface_depth, uniforms.clipping.w > .5);
        if (foreground) {continue;}
        let w=select(1.-fraction.x,fraction.x,x==1)*select(1.-fraction.y,fraction.y,y==1);
        color+=textureLoad(opaque_color,p,0)*w; total+=w;
    }}
    return select(vec4(-1.),color/max(total,1e-12),total>1e-8);
}
fn transmission_path(input:VertexOutput, n:vec3<f32>, v:vec3<f32>, surface:StandardSurface, ior:f32) -> vec4<f32> {
    let ray=refract(-v,n,1./max(ior,1.));
    let distance=surface.transmission[0].y*length(ray*input.world_scale);
    let exit_position=input.relative_position+normalized_or(ray,-v)*distance;
    let clip=uniforms.capture_projection*vec4(exit_position,1.);
    let straight_uv=input.position.xy/uniforms.viewport.xy;
    var uv=straight_uv;
    if (clip.w>1e-8 && surface.transmission[0].y>0.) {
        uv=clip.xy/clip.w*vec2(.5,-.5)+vec2(.5);
    }
    let rough=surface.roughness*clamp(ior*2.-2.,0.,1.);
    let radius=rough*rough*.08*min(uniforms.viewport.x,uniforms.viewport.y)/uniforms.viewport.xy;
    var incoming=vec4(0.); var total=0.;
    for(var y=-1;y<=1;y++) { for(var x=-1;x<=1;x++) {
        let sample=transmission_sample(uv+vec2<f32>(f32(x),f32(y))*radius,input.position.z);
        if(sample.a<0.) {continue;}
        let weight=select(1.,2.,x==0)*select(1.,2.,y==0);
        incoming+=sample*weight; total+=weight;
    }}
    if(total>0.) {incoming/=total;} else {
        incoming=transmission_sample(straight_uv,input.position.z);
        if (incoming.a<0.) { incoming=vec4(0.); }
        if (environment.params.x>0.) {
            incoming=vec4(environment_specular(ray,rough)*environment.params.x,1.);
        }
    }
    var absorption=vec3(1.);
    if(surface.transmission[0].z>0. && distance>0.) {
        absorption=pow(surface.transmission[1].rgb,vec3(distance/surface.transmission[0].z));
    }
    return vec4(incoming.rgb*absorption,incoming.a);
}
fn physical_transmission(input:VertexOutput, n:vec3<f32>, v:vec3<f32>, surface:StandardSurface) -> vec4<f32> {
    let amount=surface.transmission[0].x*(1.-surface.metallic);
    if(amount<=0.) {return vec4(0.,0.,0.,1.);}
    let nv=clamp(dot(n,v),0.,1.);
    let ior=max(surface.physical[0].x,1.);
    var incoming=transmission_path(input,n,v,surface,ior);
    if(surface.optical[1].x>0. && surface.transmission[0].y>0.) {
        let spread=(ior-1.)*.025*surface.optical[1].x;
        let red=transmission_path(input,n,v,surface,max(1.,ior-spread));
        let blue=transmission_path(input,n,v,surface,ior+spread);
        incoming=vec4(red.r,incoming.g,blue.b,max(incoming.a,max(red.a,blue.a)));
    }
    let coat=coat_fresnel(clamp(dot(surface.coat_normal,v),0.,1.),surface);
    let sheen=maximum3(surface.physical[2].rgb)*sheen_albedo(nv,surface.physical[1].w);
    let weight=amount*(1.-maximum3(physical_fresnel(nv,surface)))*(1.-coat)*(1.-sheen);
    return vec4(incoming.rgb*surface.base.rgb*weight,1.-weight*(1.-incoming.a));
}
