// Correlated-Smith GGX split sum: R=A, G=B, directional white albedo=A+B.
@vertex fn vs_energy(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
    let points = array<vec2<f32>,3>(vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));
    return vec4(points[index],0.,1.);
}
@fragment fn fs_energy(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
    let uv = (position.xy - .5) / 127.;
    return vec4(ggx_energy_integral(uv.x,uv.y,2048u),0.,1.);
}
