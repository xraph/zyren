use gpu3d_runtime::scene_packet::ScenePacket;
fn packet() -> Vec<u8> {
    let mut body = Vec::new();
    body.extend(1_u64.to_le_bytes()); // view
    body.extend(0_u64.to_le_bytes()); // base revision, full scene
    body.extend(0_u32.to_le_bytes()); // retained geometry count
    body.extend(0_u32.to_le_bytes()); // uploads
    body.extend(0_u32.to_le_bytes()); // mesh count
    body.extend(0_u32.to_le_bytes()); // updates
    for value in glam::Mat4::IDENTITY.to_cols_array() {
        body.extend(value.to_le_bytes());
    }
    for value in [0_f32, 0., 0., 0., 1., 0., 0.2] {
        body.extend(value.to_le_bytes());
    }
    let mut out = Vec::new();
    out.extend(2_u32.to_le_bytes());
    out.extend(10_u32.to_le_bytes());
    out.extend(1_u64.to_le_bytes());
    out.extend((body.len() as u64).to_le_bytes());
    out.extend(body);
    out
}
#[test]
fn binary_scene_framing_is_bounded_and_rejects_nonfinite_camera() {
    let valid = packet();
    assert!(ScenePacket::decode(&valid).is_ok());
    for end in 0..valid.len() {
        assert!(ScenePacket::decode(&valid[..end]).is_err());
    }
    let mut invalid = valid.clone();
    invalid[56..60].copy_from_slice(&f32::NAN.to_le_bytes());
    assert!(ScenePacket::decode(&invalid).is_err());
    let mut invalid = valid.clone();
    invalid[16..24].copy_from_slice(&u64::MAX.to_le_bytes());
    assert!(ScenePacket::decode(&invalid).is_err());
    let mut invalid = valid.clone();
    invalid[40..44].copy_from_slice(&u32::MAX.to_le_bytes());
    assert!(ScenePacket::decode(&invalid).is_err());
    let mut seed = 0x31ac_b455_u64;
    for len in 0..2048 {
        let random: Vec<u8> = (0..len)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                seed as u8
            })
            .collect();
        let _ = ScenePacket::decode(&random);
    }
}

fn triangle_packet(
    view: u64,
    revision: u64,
    base: u64,
    upload: bool,
    visible: bool,
    scale: f32,
) -> Vec<u8> {
    let mut data = packet();
    data[8..16].copy_from_slice(&revision.to_le_bytes());
    data[24..32].copy_from_slice(&view.to_le_bytes());
    data[32..40].copy_from_slice(&base.to_le_bytes());
    data[40..44].copy_from_slice(&1_u32.to_le_bytes());
    data[44..48].copy_from_slice(&u32::from(upload).to_le_bytes());
    data[48..52].copy_from_slice(&u32::from(visible).to_le_bytes());
    data[52..56].copy_from_slice(&u32::from(visible).to_le_bytes());
    data.extend(7_u32.to_le_bytes());
    if upload {
        for value in [7_u32, 3, 3] {
            data.extend(value.to_le_bytes());
        }
        for value in [
            -0.8_f32, -0.8, 0.4, 0.8, -0.8, 0.4, 0., 0.8, 0.4, 0., 0., 1., 0., 0., 1., 0., 0., 1.,
        ] {
            data.extend(value.to_le_bytes());
        }
        for value in [0_u32, 1, 2] {
            data.extend(value.to_le_bytes());
        }
    }
    if visible {
        data.extend(0_u32.to_le_bytes());
        data.extend(7_u32.to_le_bytes());
        let mut model = glam::Mat4::IDENTITY.to_cols_array();
        model[0] = scale;
        for value in model {
            data.extend(value.to_le_bytes());
        }
        for value in [1_f32, 0., 0.] {
            data.extend(value.to_le_bytes());
        }
        data.extend(1_u32.to_le_bytes());
    }
    let length = data.len() as u64 - 24;
    data[16..24].copy_from_slice(&length.to_le_bytes());
    data
}

#[test]
fn populated_scene_rejects_bad_ranges_and_survives_seeded_mutations() {
    let valid = triangle_packet(1, 1, 0, true, true, 1.);
    for end in 0..valid.len() {
        assert!(ScenePacket::decode(&valid[..end]).is_err());
    }
    // Header (148), owner ID (4), upload descriptor (12), six float3 values (72).
    let first_index = 236;
    let first_update = 248;
    for (offset, value) in [
        (0, 999_u32),
        (4, 11),
        (first_index, 3),
        (first_update, 1),
        (valid.len() - 4, 2),
    ] {
        let mut invalid = valid.clone();
        invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err(), "offset {offset}");
    }
    let mut missing_owner = valid.clone();
    missing_owner[148..152].copy_from_slice(&8_u32.to_le_bytes());
    assert!(
        ScenePacket::decode(&missing_owner)
            .unwrap()
            .resolve(None)
            .is_err()
    );
    let mut seed = 0xc8df_3105_u64;
    for _ in 0..4096 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let mut mutated = valid.clone();
        mutated[seed as usize % valid.len()] ^= (seed >> 32) as u8;
        if let Ok(packet) = ScenePacket::decode(&mutated)
            && let Ok(frame) = packet.resolve(None)
        {
            let _ = frame.validate(&Default::default());
        }
    }
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn rejected_deltas_preserve_the_last_valid_scene_and_shared_geometry() {
    use gpu3d_runtime::renderer::Renderer;
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let first = renderer
        .decode_scene(&triangle_packet(1, 1, 0, true, true, 1.))
        .unwrap();
    let pixels = renderer.render(&first, 31, 31).unwrap();
    assert_eq!(
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[255, 0, 0, 255]
    );
    assert_eq!(renderer.scene_resource_stats(), (84, 84));
    let invalid = renderer
        .decode_scene(&triangle_packet(1, 2, 1, false, true, 0.))
        .unwrap();
    assert!(renderer.render(&invalid, 31, 31).is_err());
    assert!(
        renderer
            .decode_scene(&triangle_packet(1, 5, 4, false, true, 1.))
            .is_err()
    );
    assert!(
        renderer
            .decode_scene(&triangle_packet(1, 2, 1, false, true, f32::NAN))
            .is_err()
    );
    let second = renderer
        .decode_scene(&triangle_packet(2, 1, 0, true, true, 1.))
        .unwrap();
    renderer.render(&second, 31, 31).unwrap();
    assert_eq!(renderer.scene_resource_stats(), (84, 84));
    let hidden = renderer
        .decode_scene(&triangle_packet(1, 2, 0, false, false, 1.))
        .unwrap();
    renderer.render(&hidden, 31, 31).unwrap();
    renderer.close_scene_view(2).unwrap();
    assert_eq!(renderer.scene_resource_stats(), (84, 84));
    let restored = renderer
        .decode_scene(&triangle_packet(1, 3, 0, false, true, 1.))
        .unwrap();
    assert_eq!(renderer.render(&restored, 31, 31).unwrap(), pixels);
    assert!(
        renderer
            .decode_scene(&triangle_packet(1, 3, 0, false, true, 1.))
            .is_err()
    );
    renderer.close_scene_view(1).unwrap();
    assert_eq!(renderer.scene_resource_stats(), (0, 84));
}
