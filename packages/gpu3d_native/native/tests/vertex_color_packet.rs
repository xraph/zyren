use gpu3d_runtime::scene_packet::ScenePacket;

fn uint(out: &mut Vec<u8>, values: &[u32]) {
    for value in values {
        out.extend(value.to_le_bytes());
    }
}
fn floats(out: &mut Vec<u8>, values: &[f32]) {
    for value in values {
        out.extend(value.to_le_bytes());
    }
}
fn packet() -> (Vec<u8>, usize, usize) {
    let mut body = Vec::new();
    body.extend(1_u64.to_le_bytes());
    body.extend(0_u64.to_le_bytes());
    uint(&mut body, &[1, 1, 1, 1]); // retained, geometry, meshes, updates
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(&mut body, &[0., 0., 0., 0., 0., 1., 0., 1.]); // background, light, ambient, alpha
    uint(&mut body, &[0, 0, 0, 0]); // lights, hemispheres, HDR, shadows
    floats(&mut body, &[0., 0., -1.]); // shadow forward
    uint(&mut body, &[0, 0, 0, 7]); // owned textures, texture uploads, patches, retained geometry
    uint(&mut body, &[7, 3, 3]); // geometry id, vertices, indices
    let flags = 24 + body.len();
    uint(&mut body, &[16, 0]); // colors, topology
    floats(&mut body, &[-1., -1., 0., 1., -1., 0., 0., 1., 0.]);
    floats(&mut body, &[0., 0., 1., 0., 0., 1., 0., 0., 1.]);
    uint(&mut body, &[0, 1, 2]);
    let color_offset = 24 + body.len();
    floats(&mut body, &[1., 0., 0., 1., 0., 1., 0., 1., 0., 0., 1., 1.]);
    uint(&mut body, &[0, 7]); // mesh index, geometry
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(&mut body, &[1., 1., 1.]);
    uint(&mut body, &[1, 0, 0]); // unlit, map, alpha mode
    floats(&mut body, &[1., 0.5]); // opacity, cutoff
    uint(&mut body, &[1, 1, 0, 0]); // depth test/write, order, primitive
    floats(&mut body, &[1.]); // primitive size
    uint(&mut body, &[0, 0, 0, 0, 0, 0, 1]); // units, shape, side, PBR, cast, receive, colors
    let mut packet = Vec::new();
    uint(&mut packet, &[2, 23]);
    packet.extend(1_u64.to_le_bytes());
    packet.extend((body.len() as u64).to_le_bytes());
    packet.extend(body);
    (packet, flags, color_offset)
}

#[test]
fn colors_survive_packets_and_reject_truncation_flags_and_nonfinite_channels() {
    let (valid, flags, colors) = packet();
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    assert_eq!(frame.geometries[0].colors[1], [0., 1., 0., 1.]);
    assert!(frame.meshes[0].vertex_colors);
    for end in 0..valid.len() {
        let mut truncated = valid[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&truncated).is_err(), "truncation {end}");
    }
    for value in [-0.01_f32, 1.01, f32::NAN, f32::INFINITY] {
        let mut invalid = valid.clone();
        invalid[colors..colors + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err());
    }
    for (offset, value) in [(flags, 32u32), (valid.len() - 4, 2)] {
        let mut invalid = valid.clone();
        invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err());
    }
    let mut disabled = valid.clone();
    let offset = disabled.len() - 4;
    disabled[offset..].copy_from_slice(&0u32.to_le_bytes());
    assert!(
        !ScenePacket::decode(&disabled)
            .unwrap()
            .resolve(None)
            .unwrap()
            .meshes[0]
            .vertex_colors
    );
    let mut legacy = valid;
    legacy[4..8].copy_from_slice(&22u32.to_le_bytes());
    assert!(ScenePacket::decode(&legacy).is_err());
}
