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
    uint(&mut body, &[0, 0, 0]); // owned textures, texture uploads, geometry patches
    let tables = 24 + body.len();
    uint(&mut body, &[1, 1, 0, 7, 9]); // instance tables, retained geometry, retained instances
    uint(&mut body, &[7, 3, 3]); // geometry id, vertices, indices
    uint(&mut body, &[16, 0]); // colors, topology
    floats(&mut body, &[-1., -1., 0., 1., -1., 0., 0., 1., 0.]);
    floats(&mut body, &[0., 0., 1., 0., 0., 1., 0., 0., 1.]);
    uint(&mut body, &[0, 1, 2]);
    floats(&mut body, &[1., 0., 0., 1., 0., 1., 0., 1., 0., 0., 1., 1.]);
    let instances = 24 + body.len();
    uint(&mut body, &[9, 2]);
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(
        &mut body,
        &glam::Mat4::from_scale(glam::Vec3::new(-1., 2., 1.)).to_cols_array(),
    );
    uint(&mut body, &[0, 7]); // mesh index, geometry
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(&mut body, &[1., 1., 1.]);
    uint(&mut body, &[1, 0, 0]); // unlit, map, alpha mode
    floats(&mut body, &[1., 0.5]); // opacity, cutoff
    uint(&mut body, &[1, 1, 0, 0]); // depth test/write, order, primitive
    floats(&mut body, &[1.]); // primitive size
    uint(&mut body, &[0, 0, 0, 0, 0, 0, 1]); // units, shape, side, PBR, cast, receive, colors
    uint(&mut body, &[9, 2]); // instance resource and draw count
    let mut packet = Vec::new();
    uint(&mut packet, &[2, 24]);
    packet.extend(1_u64.to_le_bytes());
    packet.extend((body.len() as u64).to_le_bytes());
    packet.extend(body);
    (packet, tables, instances)
}

#[test]
fn instance_packets_reject_truncation_counts_and_invalid_transforms() {
    let (valid, tables, instances) = packet();
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    assert_eq!(frame.instances[0].transforms.len(), 2);
    assert_eq!(frame.meshes[0].instance_count, 2);
    for end in 0..valid.len() {
        let mut truncated = valid[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&truncated).is_err(), "truncation {end}");
    }
    for (offset, bits) in [
        (tables, 4097),
        (tables + 4, 4097),
        (tables + 8, 4097),
        (instances, 0),
        (instances + 4, 100001),
        (instances + 8, f32::NAN.to_bits()),
        (instances + 8 + 12, 1_f32.to_bits()),
        (instances + 8 + 60, 0),
        (valid.len() - 4, 0),
        (valid.len() - 4, 100001),
    ] {
        let mut invalid = valid.clone();
        invalid[offset..offset + 4].copy_from_slice(&bits.to_le_bytes());
        assert!(
            ScenePacket::decode(&invalid).is_err(),
            "invalid field {offset}"
        );
    }
    let mut missing = valid.clone();
    let offset = missing.len() - 8;
    missing[offset..offset + 4].copy_from_slice(&10_u32.to_le_bytes());
    assert!(
        ScenePacket::decode(&missing)
            .unwrap()
            .resolve(None)
            .is_err()
    );
}

#[test]
fn color_packets_validate_every_channel_and_legacy_packets_default_to_white() {
    let (mut colored, tables, instances) = packet();
    colored[4..8].copy_from_slice(&26_u32.to_le_bytes());
    colored.splice(tables + 12..tables + 12, [0_u8; 8]); // empty pose tables
    let instances = instances + 8;
    let mut red = Vec::new();
    floats(&mut red, &[1., 0., 0.]);
    let mut blue = Vec::new();
    floats(&mut blue, &[0., 0., 1.]);
    colored.splice(instances + 136..instances + 136, blue);
    colored.splice(instances + 72..instances + 72, red);
    uint(&mut colored, &[0]); // no mesh pose
    let length = (colored.len() - 24) as u64;
    colored[16..24].copy_from_slice(&length.to_le_bytes());
    let frame = ScenePacket::decode(&colored)
        .unwrap()
        .resolve(None)
        .unwrap();
    assert_eq!(frame.instances[0].colors, [[1., 0., 0.], [0., 0., 1.]]);
    for value in [f32::NAN, f32::INFINITY, -0.1, 1.1] {
        for offset in [instances + 72, instances + 148] {
            let mut bad = colored.clone();
            bad[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
            assert!(ScenePacket::decode(&bad).is_err());
        }
    }
    for end in 24..colored.len() {
        let mut truncated = colored[..end].to_vec();
        truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        assert!(ScenePacket::decode(&truncated).is_err());
    }
    let legacy = ScenePacket::decode(&packet().0)
        .unwrap()
        .resolve(None)
        .unwrap();
    assert_eq!(legacy.instances[0].colors, [[1.; 3]; 2]);
}
