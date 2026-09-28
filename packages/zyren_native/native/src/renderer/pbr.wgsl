struct Uniforms {
    mvp: mat4x4<f32>,
    normal_matrix: mat4x4<f32>,
    color_unlit: vec4<f32>,
    light_ambient: vec4<f32>,
    map_params: vec4<f32>,
    view_projection: mat4x4<f32>,
    model: mat4x4<f32>,
    primitive: vec4<f32>,
    viewport: vec4<f32>,
};
@group(0) @binding(0) var<uniform> uniforms: Uniforms;

struct Material { factors: vec4<f32>, emissive: vec4<f32> };
struct Light { positionKind: vec4<f32>, colorIntensity: vec4<f32>, directionRange: vec4<f32>, cone: vec4<f32>, ground: vec4<f32> };
struct Lights { count: vec4<f32>, view: vec4<f32>, values: array<Light,16> };
@group(1) @binding(0) var<uniform> material: Material;
@group(1) @binding(1) var<uniform> lights: Lights;
@group(2) @binding(0) var baseMap: texture_2d<f32>;
@group(2) @binding(1) var baseSampler: sampler;
struct PbrVertex { @builtin(position) position: vec4<f32>, @location(0) normal: vec3<f32>, @location(1) point: vec3<f32>, @location(2) uv: vec2<f32> };
fn transform(position: vec3<f32>, normal: vec3<f32>) -> PbrVertex {
 var v: PbrVertex;
 v.position = uniforms.mvp * vec4<f32>(position,1.);
 v.normal = (uniforms.normal_matrix * vec4<f32>(normal,0.)).xyz;
 v.point = (uniforms.model * vec4<f32>(position,1.)).xyz;
 v.uv = vec2<f32>(0.);
 return v;
}
@vertex fn vertex(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> PbrVertex { return transform(position,normal); }
@vertex fn vertex_textured(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>, @location(2) uv0: vec2<f32>, @location(3) uv1: vec2<f32>) -> PbrVertex {
 var v = transform(position,normal);
 v.uv = select(uv0,uv1,uniforms.map_params.x > .5);
 return v;
}
fn brdf(base: vec3<f32>, metal: f32, rough: f32, n: vec3<f32>, v: vec3<f32>, l: vec3<f32>) -> vec3<f32> {
 let h = normalize(v+l);
 let nl=max(dot(n,l),0.); let nv=max(dot(n,v),0.);
 let nh=max(dot(n,h),0.); let vh=max(dot(v,h),0.);
 let a=rough*rough; let a2=a*a;
 let denom=nh*nh*(a2-1.)+1.;
 let d=a2 / (3.14159265359 * denom*denom);
 let gv=nl*sqrt(a2+(1.-a2)*nv*nv); let gl=nv*sqrt(a2+(1.-a2)*nl*nl);
 let visibility=.5/max(gv+gl,1e-6);
 let f0=mix(vec3<f32>(.04),base,metal);
 let schlick=exp2((-5.55473*vh-6.98316)*vh);
 let f=f0*(1.-schlick)+vec3<f32>(schlick);
 return nl*(base*(1.-metal)/3.14159265359 + f*visibility*d);
}
fn shade(input: PbrVertex, front: bool, sampleColor: vec4<f32>) -> vec4<f32> {
 let base=uniforms.color_unlit.rgb*sampleColor.rgb;
 let alpha=uniforms.map_params.y*sampleColor.a;
 if uniforms.map_params.w > .5 && uniforms.map_params.w < 1.5 && alpha < uniforms.map_params.z { discard; }
 let n=normalize(select(-input.normal,input.normal,front));
 let view=normalize(select(-input.point,lights.view.xyz,lights.view.w > .5));
 let metal=material.factors.x; let rough=max(material.factors.y,.0525);
 var color=material.emissive.rgb * material.factors.z;
 for(var i=0u; i<min(u32(lights.count.x),16u); i++) {
   let light=lights.values[i];
   let intensity=light.colorIntensity.rgb*light.colorIntensity.w;
   if light.positionKind.w > 2.5 {
     let irradiance=mix(light.ground.rgb*light.colorIntensity.w,intensity,dot(n,normalize(light.directionRange.xyz))*.5+.5);
     color += irradiance * base * (1.-metal) / 3.14159265359;
     continue;
   }
   var l=-normalize(light.directionRange.xyz); var attenuation=1.;
   if light.positionKind.w > .5 {
     let delta=light.positionKind.xyz-input.point; let distance=length(delta);
     l=delta/max(distance,1e-6); attenuation=1./max(distance*distance,.01);
     if light.directionRange.w > 0. { let cutoff=clamp(1.-pow(distance/light.directionRange.w,4.),0.,1.); attenuation *= cutoff*cutoff; }
     if light.positionKind.w > 1.5 {
       let angle=dot(-l,normalize(light.directionRange.xyz));
       attenuation *= select(step(light.cone.y,angle),smoothstep(light.cone.y,light.cone.x+1e-6,angle),light.cone.x > light.cone.y);
     }
   }
   if dot(n,l) > 0. && dot(n,view) > 0. {
     color += intensity * attenuation * brdf(base,metal,rough,n,view,l);
   }
 }
 return vec4<f32>(clamp(color,vec3<f32>(0.),vec3<f32>(65504.)),select(1.,alpha,uniforms.map_params.w>1.5));
}
@fragment fn fragment(input: PbrVertex,@builtin(front_facing) front: bool) -> @location(0) vec4<f32> { return shade(input,front,vec4<f32>(1.)); }
@fragment fn fragment_textured(input: PbrVertex,@builtin(front_facing) front: bool) -> @location(0) vec4<f32> { return shade(input,front,textureSample(baseMap,baseSampler,input.uv)); }
