use draco_core::{
    DataType, EncoderBuffer, EncoderOptions, FaceIndex, GeometryAttributeType, Mesh, MeshEncoder,
    PointAttribute,
};

pub fn encoded(speed: i32) -> Vec<u8> {
    let mut mesh = Mesh::new();
    mesh.set_num_points(4);
    for (id, kind, components, values) in [
        (
            77,
            GeometryAttributeType::Position,
            3,
            vec![-1f32, -1., 0., 1., -1., 0., 1., 1., 0., -1., 1., 0.],
        ),
        (
            8,
            GeometryAttributeType::Normal,
            3,
            vec![0., 0., 1., 0., 0., 1., 0., 0., 1., 0., 0., 1.],
        ),
        (
            21,
            GeometryAttributeType::TexCoord,
            2,
            vec![0., 0., 1., 0., 1., 1., 0., 1.],
        ),
    ] {
        let mut attribute = PointAttribute::new();
        attribute.init(kind, components, DataType::Float32, false, 4);
        attribute.set_unique_id(id);
        attribute
            .buffer_mut()
            .write(0, bytemuck::cast_slice(&values));
        mesh.add_attribute_preserve_unique_id(attribute);
    }
    mesh.set_num_faces(2);
    mesh.set_face(FaceIndex(0), [0u32.into(), 1u32.into(), 2u32.into()]);
    mesh.set_face(FaceIndex(1), [0u32.into(), 2u32.into(), 3u32.into()]);
    let mut options = EncoderOptions::new();
    options.set_global_int("encoding_speed", speed);
    options.set_global_int("decoding_speed", speed);
    options.set_attribute_int(0, "quantization_bits", 14);
    options.set_attribute_int(1, "quantization_bits", 10);
    options.set_attribute_int(2, "quantization_bits", 12);
    let mut encoder = MeshEncoder::new();
    encoder.set_mesh(mesh);
    let mut output = EncoderBuffer::new();
    encoder.encode(&options, &mut output).unwrap();
    output.data().to_vec()
}
