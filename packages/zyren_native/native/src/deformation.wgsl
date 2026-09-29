@group(2) @binding(0) var<storage, read> deformation_source: array<u32>;
@group(2) @binding(1) var<storage, read> deformation_pose: array<u32>;

struct DeformedVertex {
    position: vec3<f32>,
    normal: vec3<f32>,
    tangent: vec4<f32>,
};
fn deformation_vec3(offset: u32) -> vec3<f32> {
    return vec3(bitcast<f32>(deformation_source[offset]), bitcast<f32>(deformation_source[offset+1u]), bitcast<f32>(deformation_source[offset+2u]));
}
fn deformation_joint(index: u32) -> mat4x4<f32> {
    let start = 68u + index * 16u;
    var matrix: mat4x4<f32>;
    for (var column=0u; column<4u; column++) {
        let offset = start + column*4u;
        matrix[column] = vec4(bitcast<f32>(deformation_pose[offset]), bitcast<f32>(deformation_pose[offset+1u]), bitcast<f32>(deformation_pose[offset+2u]), bitcast<f32>(deformation_pose[offset+3u]));
    }
    return matrix;
}
fn deform_vertex(index: u32, position: vec3<f32>, normal: vec3<f32>, tangent: vec4<f32>) -> DeformedVertex {
    var output = DeformedVertex(position, normal, tangent);
    let vertices = deformation_pose[0];
    let morph_start = select(0u, vertices*8u, deformation_pose[3] != 0u);
    for (var morph=0u; morph<deformation_pose[1]; morph++) {
        let weight = bitcast<f32>(deformation_pose[4u+morph]);
        let offset = morph_start + (morph*vertices+index)*9u;
        output.position += deformation_vec3(offset)*weight;
        output.normal += deformation_vec3(offset+3u)*weight;
        output.tangent = vec4(output.tangent.xyz + deformation_vec3(offset+6u)*weight, output.tangent.w);
    }
    if dot(output.normal,output.normal) < 1e-20 { output.normal=normal; }
    if deformation_pose[2] == 0u { return output; }
    let start = index*8u;
    var matrix: mat4x4<f32>;
    var total=0.;
    for (var influence=0u; influence<4u; influence++) {
        let weight = bitcast<f32>(deformation_source[start+4u+influence]);
        matrix += deformation_joint(deformation_source[start+influence])*weight;
        total += weight;
    }
    matrix *= 1./total;
    output.position=(matrix*vec4(output.position,1.)).xyz;
    let linear=mat3x3(matrix[0].xyz,matrix[1].xyz,matrix[2].xyz);
    let cofactor=mat3x3(cross(linear[1],linear[2]),cross(linear[2],linear[0]),cross(linear[0],linear[1]));
    let determinant=dot(linear[0],cofactor[0]);
    if abs(determinant)>1e-10 { output.normal=cofactor*output.normal/determinant; }
    output.tangent=vec4(linear*output.tangent.xyz, output.tangent.w*select(1.,-1.,determinant<0.));
    return output;
}
