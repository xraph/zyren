use gpu3d_runtime::scene_packet::ScenePacket;
fn uint(out: &mut Vec<u8>, values: &[u32]) {
    for v in values {
        out.extend(v.to_le_bytes());
    }
}
fn floats(out: &mut Vec<u8>, values: &[f32]) {
    for v in values {
        out.extend(v.to_le_bytes());
    }
}
fn packet() -> (Vec<u8>, usize, usize, usize) {
    let mut body = Vec::new();
    body.extend(1_u64.to_le_bytes());
    body.extend(0_u64.to_le_bytes());
    uint(&mut body, &[1, 1, 1, 1]);
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(&mut body, &[0., 0., 0., 0., 0., 1., 0., 1.]);
    uint(&mut body, &[0, 0, 0, 0]);
    floats(&mut body, &[0., 0., -1.]);
    uint(&mut body, &[0, 0, 0, 0, 0, 0, 1, 1, 7, 9]); // textures, geometry patches, instances, poses, owned IDs
    uint(&mut body, &[7, 3, 3, 96, 0]); // geometry, triangle, skin and morph streams
    floats(&mut body, &[-1., -1., 0., 1., -1., 0., 0., 1., 0.]);
    floats(&mut body, &[0., 0., 1., 0., 0., 1., 0., 0., 1.]);
    uint(&mut body, &[0, 1, 2]);
    uint(&mut body, &[0; 12]);
    floats(&mut body, &[1., 0., 0., 0., 1., 0., 0., 0., 1., 0., 0., 0.]);
    let morph_count = 24 + body.len();
    uint(&mut body, &[1, 1]);
    floats(&mut body, &[1., 0., 0., 1., 0., 0., 1., 0., 0.]);
    let pose_count = 24 + body.len() + 8;
    uint(&mut body, &[9, 7, 1, 1]);
    let weight = 24 + body.len();
    floats(&mut body, &[-0.5]);
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    uint(&mut body, &[0, 7]);
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(&mut body, &[1., 1., 1.]);
    uint(&mut body, &[1, 0, 0]);
    floats(&mut body, &[1., 0.5]);
    uint(&mut body, &[1, 1, 0, 0]);
    floats(&mut body, &[1.]);
    uint(&mut body, &[0, 0, 0, 0, 0, 0, 0, 0, 1, 9]);
    let mut packet = Vec::new();
    uint(&mut packet, &[2, 25]);
    packet.extend(1_u64.to_le_bytes());
    packet.extend((body.len() as u64).to_le_bytes());
    packet.extend(body);
    (packet, morph_count, pose_count, weight)
}
#[test]
fn deformation_packets_bound_payloads_and_reject_every_truncation() {
    let (valid, morph_count, pose_count, weight) = packet();
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    assert_eq!(frame.meshes[0].pose, 9);
    assert_eq!(frame.poses[0].weights, [-0.5]);
    frame.poses[0].validate(&frame.geometries[0]).unwrap();
    for end in 0..valid.len() {
        let mut truncated = valid[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&truncated).is_err(), "truncation {end}");
    }
    for (offset, value) in [
        (morph_count, 65),
        (pose_count, 65),
        (pose_count + 4, 257),
        (weight, f32::NAN.to_bits()),
        (weight, f32::INFINITY.to_bits()),
    ] {
        let mut invalid = valid.clone();
        invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err());
    }
    let mut missing = valid.clone();
    let end = missing.len();
    missing[end - 4..].copy_from_slice(&10_u32.to_le_bytes());
    assert!(
        ScenePacket::decode(&missing)
            .unwrap()
            .resolve(None)
            .is_err()
    );
    let mut random = 0x8215_u32;
    for _ in 0..400 {
        random = random.wrapping_mul(1664525).wrapping_add(1013904223);
        let mut altered = valid.clone();
        let index = random as usize % altered.len();
        altered[index] ^= (random >> 16) as u8;
        if let Ok(packet) = ScenePacket::decode(&altered) {
            let _ = packet.resolve(None);
        }
    }
}
