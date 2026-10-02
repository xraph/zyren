use zyren_runtime::scene_packet::ScenePacket;
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
    use zyren_runtime::renderer::Renderer;
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

fn patch_packet() -> Vec<u8> {
    let mut data = triangle_packet(1, 2, 0, false, true, 1.);
    data[4..8].copy_from_slice(&12_u32.to_le_bytes());
    data[148..152].copy_from_slice(&8_u32.to_le_bytes()); // retained target
    data[156..160].copy_from_slice(&8_u32.to_le_bytes()); // mesh target
    let mut patch = Vec::new();
    for value in [8_u32, 7, 1, 0, 1, 1] {
        patch.extend(value.to_le_bytes());
    }
    for value in [0.7_f32, -0.8, 0.4] {
        patch.extend(value.to_le_bytes());
    }
    data.splice(152..152, patch);
    data.splice(
        148..148,
        [0_u32, 0, 1].into_iter().flat_map(u32::to_le_bytes),
    );
    data.extend(0_u32.to_le_bytes()); // no color map
    let length = data.len() as u64 - 24;
    data[16..24].copy_from_slice(&length.to_le_bytes());
    data
}

#[test]
fn geometry_patch_packets_bound_ranges_and_reject_every_truncation() {
    let valid = patch_packet();
    assert!(ScenePacket::decode(&valid).is_ok());
    for end in 0..valid.len() {
        let mut truncated = valid[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&truncated).is_err(), "end {end}");
    }
    for (offset, value) in [
        (164, 7_u32),
        (172, 0),
        (172, 65),
        (176, 4),
        (180, u32::MAX),
        (184, 0),
        (184, u32::MAX),
        (188, f32::NAN.to_bits()),
    ] {
        let mut invalid = valid.clone();
        invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err(), "offset {offset}");
    }
    let mut seed = 0x5091_a431_u32;
    for _ in 0..1024 {
        seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
        let mut data = valid.clone();
        let offset = seed as usize % data.len();
        data[offset] ^= (seed >> 24) as u8 | 1;
        let _ = ScenePacket::decode(&data);
    }
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn failed_geometry_patches_preserve_pixels_ownership_and_revisions() {
    use zyren_runtime::renderer::Renderer;
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let first = renderer
        .decode_scene(&triangle_packet(1, 1, 0, true, true, 1.))
        .unwrap();
    let pixels = renderer.render(&first, 31, 31).unwrap();
    let valid = patch_packet();
    let mut missing = valid.clone();
    missing[168..172].copy_from_slice(&99_u32.to_le_bytes());
    assert!(renderer.decode_scene(&missing).is_err());
    let mut bad_normal = valid.clone();
    bad_normal[176..180].copy_from_slice(&1_u32.to_le_bytes());
    bad_normal[188..200].fill(0);
    assert!(renderer.decode_scene(&bad_normal).is_err());
    let mut bad_mesh = valid.clone();
    bad_mesh[208..212].fill(0);
    let invalid = renderer.decode_scene(&bad_mesh).unwrap();
    assert!(renderer.render(&invalid, 31, 31).is_err());
    assert_eq!(renderer.scene_resource_stats(), (84, 84));
    // Same revision still applies after the rejected request.
    let patch = renderer.decode_scene(&valid).unwrap();
    let changed = renderer.render(&patch, 31, 31).unwrap();
    assert_eq!(
        &changed[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4]
    );
    assert_eq!(renderer.scene_resource_stats(), (84, 108));
    renderer.close_scene_view(1).unwrap();
    assert_eq!(renderer.scene_resource_stats(), (0, 108));
}

fn compact_triangle_packet() -> Vec<u8> {
    let mut data = triangle_packet(1, 1, 0, true, true, 1.);
    data[4..8].copy_from_slice(&13_u32.to_le_bytes());
    data.splice(
        236..248,
        [0_u16, 1, 2].into_iter().flat_map(u16::to_le_bytes),
    );
    data.splice(164..164, 4_u32.to_le_bytes()); // uint16, no UVs
    data.splice(148..148, [0_u32; 3].into_iter().flat_map(u32::to_le_bytes));
    data.extend(0_u32.to_le_bytes()); // no color map
    let length = data.len() as u64 - 24;
    data[16..24].copy_from_slice(&length.to_le_bytes());
    data
}

#[test]
fn compact_indices_preserve_unaligned_fields_and_reject_truncation() {
    let valid = compact_triangle_packet();
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    assert_eq!(frame.geometries[0].indices, [0, 1, 2]);
    assert_eq!(frame.geometries[0].byte_length(), 78);
    assert_eq!(frame.meshes[0].geometry, 7);
    for end in 0..valid.len() {
        let mut data = valid[..end].to_vec();
        if end >= 24 {
            data[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&data).is_err(), "end {end}");
    }
    for (offset, value) in [(4, 12_u32), (176, 8), (176, 0)] {
        let mut data = valid.clone();
        data[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&data).is_err());
    }
    let mut data = valid.clone();
    data[254..256].copy_from_slice(&3_u16.to_le_bytes());
    assert!(ScenePacket::decode(&data).is_err());
    let mut seed = 0x3159_b223_u64;
    for _ in 0..1024 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let mut data = valid.clone();
        data[seed as usize % valid.len()] ^= (seed >> 32) as u8;
        let _ = ScenePacket::decode(&data);
    }
}

fn alpha_packet() -> (Vec<u8>, usize) {
    let mut data = triangle_packet(1, 1, 0, true, true, 1.);
    data[4..8].copy_from_slice(&15_u32.to_le_bytes());
    data.splice(148..148, [0_u8; 12]); // Texture counts and geometry patch count.
    data.splice(176..176, 0_u32.to_le_bytes()); // UV/index flags.
    data.extend(0_u32.to_le_bytes()); // No color map.
    let material = data.len();
    for value in [
        2_u32,
        0.5_f32.to_bits(),
        0.5_f32.to_bits(),
        1,
        0,
        (-4_i32) as u32,
    ] {
        data.extend(value.to_le_bytes());
    }
    let length = (data.len() - 24) as u64;
    data[16..24].copy_from_slice(&length.to_le_bytes());
    (data, material)
}

#[test]
fn alpha_packet_validates_policy_ranges_flags_and_truncations() {
    let (valid, material) = alpha_packet();
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    frame.validate(&Default::default()).unwrap();
    assert_eq!(frame.meshes[0].alpha_mode, 2);
    assert_eq!(frame.meshes[0].render_order, -4);
    assert!(!frame.meshes[0].writes_depth());
    let mut above_one = valid.clone();
    above_one[material + 8..material + 12].copy_from_slice(&1.1_f32.to_le_bytes());
    assert!(ScenePacket::decode(&above_one).is_ok());
    for (offset, value) in [
        (0, 3_u32),
        (4, f32::NAN.to_bits()),
        (4, (-0.1_f32).to_bits()),
        (8, (-0.1_f32).to_bits()),
        (8, f32::INFINITY.to_bits()),
        (12, 2),
        (16, 2),
    ] {
        let mut invalid = valid.clone();
        invalid[material + offset..material + offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err());
    }
    for end in 0..valid.len() {
        let mut data = valid[..end].to_vec();
        if end >= 24 {
            data[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&data).is_err());
    }
    let mut seed = 0x834f_2348_u64;
    for _ in 0..2048 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let mut data = valid.clone();
        data[material + seed as usize % 24] ^= (seed >> 32) as u8;
        if let Ok(packet) = ScenePacket::decode(&data)
            && let Ok(frame) = packet.resolve(None)
        {
            let _ = frame.validate(&Default::default());
        }
    }
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn rejected_materials_preserve_revision_and_legacy_opaque_defaults() {
    use zyren_runtime::renderer::Renderer;
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let (mut packet, material) = alpha_packet();
    let first = renderer.decode_scene(&packet).unwrap();
    let pixels = renderer.render(&first, 31, 31).unwrap();
    assert!(pixels[(15 * 31 + 15) * 4].abs_diff(188) <= 1);
    packet[8..16].copy_from_slice(&2_u64.to_le_bytes());
    packet[material..material + 4].copy_from_slice(&3_u32.to_le_bytes());
    assert!(renderer.decode_scene(&packet).is_err());
    let restored = renderer
        .decode_scene(&triangle_packet(1, 2, 1, false, true, 1.))
        .unwrap();
    assert_eq!(restored.meshes[0].opacity, 1.);
    assert!(restored.meshes[0].writes_depth());
    let pixels = renderer.render(&restored, 31, 31).unwrap();
    assert_eq!(
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[255, 0, 0, 255]
    );
    assert_eq!(renderer.scene_resource_stats(), (84, 84));
}

fn primitive_packet() -> Vec<u8> {
    let (mut data, _) = alpha_packet();
    data[4..8].copy_from_slice(&16_u32.to_le_bytes());
    data.splice(180..180, 3_u32.to_le_bytes()); // Three point markers.
    for value in [2_u32, 12_f32.to_bits(), 0, 1] {
        data.extend(value.to_le_bytes());
    }
    let length = (data.len() - 24) as u64;
    data[16..24].copy_from_slice(&length.to_le_bytes());
    data
}
#[test]
fn primitive_packets_bound_topology_size_and_expansion() {
    let valid = primitive_packet();
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    frame.validate(&Default::default()).unwrap();
    assert_eq!(frame.geometries[0].byte_length(), 360);
    assert_eq!(frame.meshes[0].primitive_size, 12.);
    let material = valid.len() - 16;
    for (offset, value) in [
        (180, 4_u32),
        (180, 1),
        (material, 3),
        (material + 4, f32::NAN.to_bits()),
        (material + 4, 0_f32.to_bits()),
        (material + 4, 4097_f32.to_bits()),
        (material + 8, 2),
        (material + 12, 2),
    ] {
        let mut data = valid.clone();
        data[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&data).is_err(), "offset {offset}");
    }
    for end in 0..valid.len() {
        let mut data = valid[..end].to_vec();
        if end >= 24 {
            data[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&data).is_err(), "end {end}");
    }
    let mut seed = 0xe170_2239_u64;
    for _ in 0..2048 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let mut data = valid.clone();
        data[seed as usize % valid.len()] ^= (seed >> 32) as u8;
        if let Ok(packet) = ScenePacket::decode(&data)
            && let Ok(frame) = packet.resolve(None)
        {
            let _ = frame.validate(&Default::default());
        }
    }
    let mut geometry = frame.geometries[0].clone();
    geometry.indices = vec![0; 250001];
    assert!(geometry.validate().is_err());
    geometry.indices = vec![0; 250000];
    assert!(geometry.validate().is_ok());
    assert_eq!(geometry.byte_length(), 30_000_000);
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn incompatible_primitive_material_preserves_pixels_and_residency() {
    use zyren_runtime::renderer::Renderer;
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let first = renderer.decode_scene(&primitive_packet()).unwrap();
    let pixels = renderer.render(&first, 64, 64).unwrap();
    assert!(pixels.chunks_exact(4).any(|p| p[0] > 0));
    let mut invalid = first.clone();
    invalid.meshes[0].primitive_kind = 0;
    assert!(renderer.render(&invalid, 64, 64).is_err());
    assert_eq!(renderer.render(&first, 64, 64).unwrap(), pixels);
    assert_eq!(renderer.scene_resource_stats(), (360, 360));
}

#[test]
fn sided_packets_validate_flags_and_preserve_legacy_defaults() {
    let mut valid = primitive_packet();
    valid[4..8].copy_from_slice(&17_u32.to_le_bytes());
    valid[180..184].copy_from_slice(&0_u32.to_le_bytes()); // triangles
    let primitive = valid.len() - 16;
    valid[primitive..primitive + 4].copy_from_slice(&0_u32.to_le_bytes());
    valid.extend(1_u32.to_le_bytes());
    let length = (valid.len() - 24) as u64;
    valid[16..24].copy_from_slice(&length.to_le_bytes());
    let frame = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
    assert_eq!(frame.meshes[0].side, 1);
    for value in [3_u32, u32::MAX] {
        let mut invalid = valid.clone();
        let offset = invalid.len() - 4;
        invalid[offset..].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err());
    }
    for end in 0..valid.len() {
        let mut data = valid[..end].to_vec();
        if end >= 24 {
            data[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&data).is_err(), "end {end}");
    }
    let mut mixed = valid.clone();
    mixed[primitive..primitive + 4].copy_from_slice(&2_u32.to_le_bytes());
    assert!(ScenePacket::decode(&mixed).is_err());
    let legacy = ScenePacket::decode(&primitive_packet())
        .unwrap()
        .resolve(None)
        .unwrap();
    assert_eq!(legacy.meshes[0].side, 0);
}

#[test]
fn background_alpha_extends_packets_without_changing_legacy_defaults() {
    let legacy = ScenePacket::decode(&packet())
        .unwrap()
        .resolve(None)
        .unwrap();
    assert_eq!(legacy.background_alpha, 1.);
    let mut data = packet();
    data[4..8].copy_from_slice(&18_u32.to_le_bytes());
    data.extend(0.5_f32.to_le_bytes());
    data.extend([0_u8; 12]); // texture ownership, uploads, patches
    let length = data.len() as u64 - 24;
    data[16..24].copy_from_slice(&length.to_le_bytes());
    let frame = ScenePacket::decode(&data).unwrap().resolve(None).unwrap();
    assert_eq!(frame.background_alpha, 0.5);
    for value in [-0.1, 1.1, f32::NAN, f32::INFINITY] {
        data[148..152].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&data).is_err());
    }
    for value in [0_f32, 1.] {
        data[148..152].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&data).is_ok());
    }
}
