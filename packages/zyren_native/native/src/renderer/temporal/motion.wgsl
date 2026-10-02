struct MotionUniform {
    current_mvp: mat4x4<f32>, previous_mvp: mat4x4<f32>, unjittered_mvp: mat4x4<f32>,
    params: vec4<f32>, // valid history, previous instance count, alpha mode, alpha cutoff
    alpha: vec4<f32>, // opacity, UV set, reactive, has map
    raster: vec4<f32>, // material side
    inverse_vp: mat4x4<f32>, planes: array<vec4<f32>,6>, clipping: vec4<f32>,
};
@group(0) @binding(0) var<uniform> uniforms: MotionUniform;
@group(1) @binding(0) var color_map: texture_2d<f32>;
@group(1) @binding(1) var color_sampler: sampler;
struct Output {
    @builtin(position) position: vec4<f32>,
    @location(0) previous: vec4<f32>,
    @location(1) current_clip: vec4<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) alpha: f32,
    @location(4) @interpolate(flat) valid: f32,
    @location(5) @interpolate(flat) orientation: f32,
    @location(6) relative: vec3<f32>,
};
struct Instance {
    @location(4) current0:vec4<f32>,@location(5) current1:vec4<f32>,@location(6) current2:vec4<f32>,@location(7) current3:vec4<f32>,
    @location(8) previous0:vec4<f32>,@location(9) previous1:vec4<f32>,@location(10) previous2:vec4<f32>,@location(11) previous3:vec4<f32>,
    @location(13) color:vec4<f32>, @location(14) previous_color:vec4<f32>,
};
fn vertex_data(position:vec3<f32>,previous:vec3<f32>,uv0:vec2<f32>,uv1:vec2<f32>,alpha:f32,instance:u32) -> Output {
    let clip=uniforms.current_mvp*vec4(position,1.);
    return Output(clip,uniforms.previous_mvp*vec4(previous,1.),uniforms.unjittered_mvp*vec4(position,1.),select(uv0,uv1,uniforms.alpha.y>.5),alpha,
        uniforms.params.x*select(0.,1.,f32(instance)<uniforms.params.y),1.,(uniforms.inverse_vp*clip).xyz);
}
// The vertex entry below is generated from the active geometry layout.
__VERTEX__
@fragment fn fragment(input:Output,@builtin(front_facing) front:bool) -> @location(0) vec4<f32> {
    for(var i=0u;i<u32(uniforms.clipping.x);i++) {
        if(dot(uniforms.planes[i],vec4(input.relative,1.))<0.) { discard; }
    }
    fragment_coverage(input.position.xy,uniforms.clipping.yz);
    let facing=select(!front,front,input.orientation>0.);
    if((uniforms.raster.x==1. && !facing)||(uniforms.raster.x==2. && facing)){discard;}
    var alpha=input.alpha*uniforms.alpha.x;
    if(uniforms.alpha.w>.5) { alpha*=textureSample(color_map,color_sampler,input.uv).a; }
    if(uniforms.params.z>.5 && uniforms.params.z<1.5 && alpha<uniforms.params.w) { discard; }
    if(uniforms.params.z>1.5 && alpha<=0.) { discard; }
    let clip=input.previous;
    if(uniforms.alpha.z>.5) { return vec4(0.,0.,0.,-1.); }
    if(input.valid<.5 || clip.w<=0.) { return vec4(0.); }
    let previous_ndc=clip.xyz/clip.w;
    let current_ndc=input.current_clip.xy/input.current_clip.w;
    return vec4((previous_ndc.xy-current_ndc)*vec2(.5,-.5),previous_ndc.z,1.);
}
