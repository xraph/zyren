const cloudBlueNoiseWgsl = r'''
@group(2) @binding(7) var<storage,read> cloudBlueNoise:array<u32>;
fn cloudNoise(pixel:vec2<f32>,height:f32)->f32{
 let p=vec2<u32>(u32(pixel.x),u32(height)-1u-u32(pixel.y));
 if(arrayLength(&cloudBlueNoise)==262144u){
  let index=(u32(cf.extent.w)%64u)*16384u+(p.y%128u)*128u+p.x%128u;
  return f32((cloudBlueNoise[index/4u]>>((index%4u)*8u))&255u)/255.;
 }
 return cloudJitter(vec2<f32>(p)+vec2<f32>(f32(u32(cf.extent.w)%64u)*5.588238));
}
''';
