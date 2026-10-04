struct ScreenLighting { ao: vec4<f32>, reflection: vec4<f32> };
@group(0) @binding(16) var<uniform> screen_lighting: ScreenLighting;
@group(0) @binding(17) var screen_radiance: texture_2d<f32>;
@group(0) @binding(18) var screen_depth: texture_depth_2d;
fn screen_background(depth: f32) -> bool {
    return select(depth >= 1., depth <= 0., uniforms.clipping.w > .5);
}
fn screen_position(pixel: vec2<i32>, depth: f32) -> vec3<f32> {
    let uv=(vec2<f32>(pixel)+vec2(.5))/vec2<f32>(textureDimensions(screen_depth));
    let p=uniforms.inverse_view_projection*vec4(uv*vec2(2.,-2.)+vec2(-1.,1.),depth,1.);
    return p.xyz/p.w;
}
fn screen_uv(position: vec3<f32>) -> vec3<f32> {
    let p=uniforms.capture_projection*vec4(position,1.);
    return vec3(p.xy/p.w*vec2(.5,-.5)+vec2(.5),p.w);
}
fn screen_inside(uv: vec2<f32>) -> bool {return all(uv>=vec2(0.)) && all(uv<vec2(1.));}
fn screen_ao(pixel: vec2<f32>, p: vec3<f32>, n: vec3<f32>, pixel_size: f32) -> f32 {
    if (screen_lighting.ao.w==0.) {return 1.;}
    let extent=vec2<f32>(textureDimensions(screen_depth));
    let radius=screen_lighting.ao.x;
    let pixel_radius=min(radius/max(pixel_size,1e-6),128.);
    var blocked=0.;
    for(var i=0u;i<u32(screen_lighting.ao.w);i++) {
        // Fixed golden-angle disk. Camera cuts never inherit a random phase.
        let f=(f32(i)+.5)/screen_lighting.ao.w;
        let angle=f32(i)*2.39996323;
        let qpixel=vec2<i32>(floor(pixel+vec2(cos(angle),sin(angle))*sqrt(f)*pixel_radius));
        if (any(qpixel<vec2(0)) || any(qpixel>=vec2<i32>(extent))) {continue;}
        let depth=textureLoad(screen_depth,qpixel,0);
        if (screen_background(depth)) {continue;}
        let delta=screen_position(qpixel,depth)-p;
        let distance=length(delta);
        let elevation=dot(n,delta);
        if(distance>1e-5 && distance<radius && elevation>screen_lighting.ao.z) {
            blocked+=clamp(elevation/distance,0.,1.)*(1.-distance/radius);
        }
    }
    return clamp(1.-2.*screen_lighting.ao.y*blocked/screen_lighting.ao.w,0.,1.);
}
fn screen_hit_color(pixel: vec2<i32>, point: vec3<f32>, roughness: f32, distance: f32) -> vec3<f32> {
    if (roughness<=.05) {return textureLoad(screen_radiance,pixel,0).rgb;}
    let extent=vec2<i32>(textureDimensions(screen_depth));
    let footprint=clamp(roughness*roughness*distance/max(length(point),.01)*f32(extent.y),1.,8.);
    var sum=vec3(0.); var count=0.;
    let offsets=array<vec2<f32>,4>(vec2(0.),vec2(-.866,-.5),vec2(.866,-.5),vec2(0.,1.));
    for(var i=0u;i<4u;i++) {
        let offset=offsets[i];
        let q=pixel+vec2<i32>(round(offset*footprint));
        if(any(q<vec2(0)) || any(q>=extent)) {continue;}
        let d=textureLoad(screen_depth,q,0);
        if(screen_background(d)) {continue;}
        let sample_point=screen_position(q,d);
        if(abs(length(sample_point)-length(point))>screen_lighting.reflection.y) {continue;}
        sum+=textureLoad(screen_radiance,q,0).rgb; count+=1.;
    }
    return sum/max(count,1.);
}
fn screen_reflection(p: vec3<f32>, n: vec3<f32>, v: vec3<f32>, roughness: f32) -> vec4<f32> {
    if(screen_lighting.reflection.w==0. || roughness>=screen_lighting.reflection.z) {return vec4(0.);}
    let direction=reflect(-v,n);
    let steps=u32(screen_lighting.reflection.w);
    let thickness=screen_lighting.reflection.y;
    let origin=p+n*max(screen_lighting.ao.z,.001);
    var previous_gap=-thickness;
    let extent=vec2<f32>(textureDimensions(screen_depth));
    for(var i=1u;i<=steps;i++) {
        // Quadratic spacing puts more tests near the receiver.
        let fraction=f32(i)/f32(steps);
        let distance=screen_lighting.reflection.x*fraction*fraction;
        let ray=origin+direction*distance;
        let projection=screen_uv(ray);
        if(projection.z<=0. || !screen_inside(projection.xy)) {return vec4(0.);}
        let pixel=vec2<i32>(projection.xy*extent);
        let depth=textureLoad(screen_depth,pixel,0);
        if(screen_background(depth)) {previous_gap=-thickness;continue;}
        let hit=screen_position(pixel,depth);
        let gap=length(ray)-length(hit);
        if(previous_gap<0. && gap>=0. && gap<=thickness && length(hit-p)>max(.02,screen_lighting.ao.z*2.)) {
            let edge=min(min(projection.x,1.-projection.x),min(projection.y,1.-projection.y));
            let confidence=smoothstep(0.,.05,edge)*(1.-smoothstep(screen_lighting.reflection.z*.8,screen_lighting.reflection.z,roughness));
            return vec4(screen_hit_color(pixel,hit,roughness,distance),confidence);
        }
        previous_gap=gap;
    }
    return vec4(0.);
}
