struct Uniforms { mvp:mat4x4<f32>, params:vec4<f32>, model:mat4x4<f32>, clipping_planes:array<vec4<f32>,6>, clipping:vec4<f32> };
@group(0) @binding(0) var<uniform> uniforms:Uniforms;
@group(1) @binding(0) var color:texture_2d<f32>;
@group(1) @binding(1) var colorSampler:sampler;
struct Vertex { @builtin(position) position:vec4<f32>, @location(0) uv:vec2<f32>, @location(1) point:vec3<f32> };
@vertex fn plain(@location(0) position:vec3<f32>)->Vertex {
 var v:Vertex;v.point=(uniforms.model*vec4<f32>(position,1.)).xyz;v.position=uniforms.mvp*vec4<f32>(position,1.);v.uv=vec2<f32>(0.);return v;
}
@vertex fn textured(@location(0) position:vec3<f32>,@location(2) uv0:vec2<f32>,@location(3) uv1:vec2<f32>)->Vertex {
 var v:Vertex;v.point=(uniforms.model*vec4<f32>(position,1.)).xyz;v.position=uniforms.mvp*vec4<f32>(position,1.);v.uv=select(uv0,uv1,uniforms.params.x>.5);return v;
}
@fragment fn fragment(v:Vertex) {
 let alpha=textureSample(color,colorSampler,v.uv).a*uniforms.params.y;
 for(var i=0u;i<u32(uniforms.clipping.x);i++) {
   if dot(uniforms.clipping_planes[i],vec4<f32>(v.point,1.))<0. {discard;}
 }
 if uniforms.params.w>.5 && alpha<uniforms.params.z {discard;}
}
@vertex fn plain_instanced(@location(0) position:vec3<f32>,i:InstanceTransform)->Vertex {
 return Vertex(uniforms.mvp*instanceModel(i)*vec4<f32>(position,1.),vec2<f32>(0.),(instanceModel(i)*vec4<f32>(position,1.)).xyz);
}
@vertex fn textured_instanced(@location(0) position:vec3<f32>,@location(2) uv0:vec2<f32>,@location(3) uv1:vec2<f32>,i:InstanceTransform)->Vertex {
 return Vertex(uniforms.mvp*instanceModel(i)*vec4<f32>(position,1.),select(uv0,uv1,uniforms.params.x>.5),(instanceModel(i)*vec4<f32>(position,1.)).xyz);
}
