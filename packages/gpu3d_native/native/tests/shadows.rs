use gpu3d_runtime::{
    lighting::PunctualLight,
    scene_packet::ScenePacket,
    shadows::{ShadowFrame, ShadowView},
};

fn view(kind: u32, resolution: u32) -> ShadowView {
    ShadowView {
        light_index: 0,
        kind,
        resolution,
        revision: 0,
        view_projection: glam::Mat4::IDENTITY.to_cols_array(),
        near: 0.1,
        far: 100.,
        blend: 0.1,
        strength: 1.,
        bias: 0.0005,
        normal_bias: 0.02,
        slope_bias: 0.002,
        filter_radius: 1.,
    }
}
fn light(kind: u32) -> PunctualLight {
    PunctualLight {
        kind,
        color: [1.; 3],
        intensity: 1.,
        position: [0.; 3],
        direction: [0., 0., -1.],
        range: 0.,
        inner_cos: 1.,
        outer_cos: 0.7,
    }
}
#[test]
fn shadow_admission_rejects_missing_faces_invalid_matrices_and_overlapping_intervals() {
    let mut shadows = ShadowFrame {
        forward: [0., 0., -1.],
        views: vec![view(0, 512)],
    };
    assert!(shadows.validate(&[light(0)]).is_ok());
    shadows.views[0].light_index = u32::MAX;
    assert!(shadows.validate(&[light(0)]).is_err());
    for invalid in [0., f32::NAN, f32::INFINITY] {
        shadows.views = vec![view(0, 512)];
        shadows.views[0].view_projection[0] = invalid;
        assert!(shadows.validate(&[light(0)]).is_err());
    }
    shadows.views = vec![view(0, 512); 2];
    assert!(shadows.validate(&[light(0)]).is_err());
    shadows.views[1].near = 100.;
    shadows.views[1].far = 200.;
    assert!(shadows.validate(&[light(0)]).is_ok());
    shadows.views[1].normal_bias = -1.;
    assert!(shadows.validate(&[light(0)]).is_err());
    for count in 1..=7 {
        shadows.views = vec![view(1, 256); count];
        assert_eq!(shadows.validate(&[light(1)]).is_ok(), count == 6);
    }
    shadows.views = vec![view(2, 512); 2];
    assert!(shadows.validate(&[light(2)]).is_err());
    shadows.views = vec![view(0, 128); 33];
    assert!(shadows.validate(&[light(0)]).is_err());
}
#[test]
fn descending_power_of_two_atlas_packing_is_bounded_disjoint_and_deterministic() {
    let mut seed = 567_u64;
    let mut fitted = 0;
    for iteration in 0..1000 {
        let mut shadows = ShadowFrame::default();
        let mut area = 0;
        for _ in 0..(iteration % 32 + 1) {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let size = 128 << (seed % 4);
            area += size * size;
            shadows.views.push(view(0, size));
        }
        let result = shadows.pack();
        assert_eq!(result.is_ok(), area <= 2048 * 2048);
        if let Ok(rects) = result {
            fitted += 1;
            assert_eq!(rects, shadows.pack().unwrap());
            for (i, a) in rects.iter().enumerate() {
                assert!(a.x + a.size <= 2048 && a.y + a.size <= 2048);
                for b in &rects[i + 1..] {
                    assert!(
                        a.x + a.size <= b.x
                            || b.x + b.size <= a.x
                            || a.y + a.size <= b.y
                            || b.y + b.size <= a.y
                    );
                }
            }
        }
    }
    assert!(fitted > 100);
    let shadows = ShadowFrame {
        views: vec![view(0, 1024); 4],
        ..Default::default()
    };
    assert_eq!(shadows.pack().unwrap().len(), 4);
}
fn packet() -> (Vec<u8>, usize, usize) {
    let mut body = Vec::new();
    body.extend(1_u64.to_le_bytes());
    body.extend(0_u64.to_le_bytes());
    body.extend([0_u8; 16]);
    for value in glam::Mat4::IDENTITY.to_cols_array() {
        body.extend(value.to_le_bytes());
    }
    for value in [0_f32, 0., 0., 0., 0., 1., 0., 1.] {
        body.extend(value.to_le_bytes());
    }
    body.extend(1_u32.to_le_bytes());
    body.extend(0_u32.to_le_bytes());
    for value in [1_f32, 1., 1., 1., 0., 0., 0., 0., 0., -1., 0., 1., 0.7] {
        body.extend(value.to_le_bytes());
    }
    body.extend(0_u32.to_le_bytes()); // hemispheres
    let hdr_offset = 24 + body.len();
    body.extend(0_u32.to_le_bytes()); // HDR absent
    let count_offset = 24 + body.len();
    body.extend(1_u32.to_le_bytes());
    for value in [0_f32, 0., -1.] {
        body.extend(value.to_le_bytes());
    }
    for value in [0_u32, 0, 512, 0] {
        body.extend(value.to_le_bytes());
    }
    for value in glam::Mat4::IDENTITY.to_cols_array() {
        body.extend(value.to_le_bytes());
    }
    for value in [0.1_f32, 100., 0.1, 1., 0.0005, 0.02, 0.002, 1.] {
        body.extend(value.to_le_bytes());
    }
    body.extend([0_u8; 12]); // retained images, uploaded images, patches
    let mut packet = Vec::new();
    packet.extend(2_u32.to_le_bytes());
    packet.extend(22_u32.to_le_bytes());
    packet.extend(1_u64.to_le_bytes());
    packet.extend((body.len() as u64).to_le_bytes());
    packet.extend(body);
    (packet, count_offset, hdr_offset)
}
#[test]
fn shadow_packets_reject_every_truncation_and_malformed_tables() {
    let (valid, count, hdr) = packet();
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    assert_eq!(frame.shadows.views.len(), 1);
    assert!(frame.color_pipeline.is_none());
    for end in 0..valid.len() {
        let mut truncated = valid[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(
            ScenePacket::decode(&truncated).is_err(),
            "accepted truncation {end}"
        );
    }
    for (offset, bits) in [
        (count, 33),
        (hdr, 2),
        (count + 16, u32::MAX),
        (count + 20, 3),
        (count + 24, 129),
        (count + 32, f32::NAN.to_bits()),
        (count + 104, (-1_f32).to_bits()),
    ] {
        let mut invalid = valid.clone();
        invalid[offset..offset + 4].copy_from_slice(&bits.to_le_bytes());
        assert!(
            ScenePacket::decode(&invalid).is_err(),
            "accepted invalid field {offset}"
        );
    }
}
