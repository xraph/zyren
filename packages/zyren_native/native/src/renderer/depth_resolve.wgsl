@group(0) @binding(0) var source:texture_depth_multisampled_2d;
@vertex fn vertex(@builtin(vertex_index) index:u32)->@builtin(position) vec4<f32> {
 let uv=vec2<f32>(f32((index<<1u)&2u),f32(index&2u));
 return vec4<f32>(uv*2.-1.,0.,1.);
}
@fragment fn fragment(@builtin(position) position:vec4<f32>)->@builtin(frag_depth) f32 {
 let p=vec2<i32>(position.xy);
 return min(min(textureLoad(source,p,0),textureLoad(source,p,1)),min(textureLoad(source,p,2),textureLoad(source,p,3)));
}
