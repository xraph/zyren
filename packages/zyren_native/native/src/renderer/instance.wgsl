struct InstanceTransform {
 @location(5) a:vec4<f32>, @location(6) b:vec4<f32>,
 @location(7) c:vec4<f32>, @location(8) d:vec4<f32>,
 @location(9) x:vec4<f32>, @location(10) y:vec4<f32>, @location(11) z:vec4<f32>,
};
fn instanceModel(i:InstanceTransform)->mat4x4<f32> {return mat4x4<f32>(i.a,i.b,i.c,i.d);}
fn instanceNormal(i:InstanceTransform)->mat3x3<f32> {return mat3x3<f32>(i.x.xyz,i.y.xyz,i.z.xyz);}
