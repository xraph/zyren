use gpu3d_runtime::{renderer::Renderer, scene::Frame, scene_packet::ScenePacket};
use serde_json::json;

fn image_packet() -> Vec<u8> {
    let mut body = Vec::new();
    body.extend(1_u64.to_le_bytes());
    body.extend(0_u64.to_le_bytes());
    for _ in 0..4 {
        body.extend(0_u32.to_le_bytes());
    }
    for v in glam::Mat4::IDENTITY.to_cols_array() {
        body.extend(v.to_le_bytes());
    }
    for v in [0_f32, 0., 0., 0., 0., 1., 0.2] {
        body.extend(v.to_le_bytes());
    }
    for v in [1_u32, 1, 7, 7, 2, 2, 1, 1, 16] {
        body.extend(v.to_le_bytes());
    }
    body.extend([255_u8; 16]);
    let mut result = Vec::new();
    result.extend(2_u32.to_le_bytes());
    result.extend(11_u32.to_le_bytes());
    result.extend(1_u64.to_le_bytes());
    result.extend((body.len() as u64).to_le_bytes());
    result.extend(body);
    result
}
#[test]
fn image_packet_bounds_and_seeded_mutations() {
    let valid = image_packet();
    assert!(ScenePacket::decode(&valid).is_ok());
    for end in 0..valid.len() {
        assert!(ScenePacket::decode(&valid[..end]).is_err());
    }
    for (offset, value) in [
        (148, 4097_u32),
        (152, 4097),
        (164, 0),
        (168, u32::MAX),
        (172, 2),
        (176, 14),
        (180, 17),
    ] {
        let mut bad = valid.clone();
        bad[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&bad).is_err(), "offset {offset}");
    }
    let mut seed = 0x94e1_b587_u64;
    for _ in 0..4096 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let mut packet = valid.clone();
        packet[seed as usize % valid.len()] ^= (seed >> 32) as u8;
        let _ = ScenePacket::decode(&packet);
    }
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn invalid_textures_leave_the_last_valid_native_frame_usable() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let identity = glam::Mat4::IDENTITY.to_cols_array();
    let mut data = json!({
        "version":1,"view_projection":identity,"background":[0,0,0],
        "light_direction":[0,0,1],"ambient":0.2,
        "geometries":[{"id":1,"positions":[[-1,-1,0.4],[1,-1,0.4],[0,1,0.4]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2],
            "uv0":[[0,0],[1,0],[0,1]]}],
        "textures":[{"id":7,"width":1,"height":1,"format":1,"levels":[[128,128,128,255]]}],
        "meshes":[{"geometry":1,"model":identity,"color":[1,1,1],"unlit":true,
            "color_map":{"texture":7,"uv_set":0,"sampler":[0,0,0,0,0]}}]
    });
    let first: Frame = serde_json::from_value(data.clone()).unwrap();
    let pixels = renderer.render(&first, 31, 31).unwrap();
    assert_eq!(
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[128, 128, 128, 255]
    );
    data["geometries"] = json!([]);
    data["textures"] = json!([]);
    let valid: Frame = serde_json::from_value(data.clone()).unwrap();
    for field in ["uv_set", "texture"] {
        let mut invalid = data.clone();
        invalid["meshes"][0]["color_map"][field] = json!(1);
        assert!(
            renderer
                .render(&serde_json::from_value(invalid).unwrap(), 31, 31)
                .is_err()
        );
        assert_eq!(renderer.render(&valid, 31, 31).unwrap(), pixels);
    }
    let mut invalid = data.clone();
    invalid["textures"] = json!([{"id":7,"width":1,"height":1,"format":1,"levels":[[0,0,0,255]]}]);
    assert!(
        renderer
            .render(&serde_json::from_value(invalid).unwrap(), 31, 31)
            .is_err()
    );
    assert_eq!(renderer.render(&valid, 31, 31).unwrap(), pixels);
}

#[test]
fn textured_mesh_packet_rejects_invalid_uvs_and_sampler_fields() {
    let mut packet = image_packet();
    for offset in [40, 44, 48, 52] {
        packet[offset..offset + 4].copy_from_slice(&1_u32.to_le_bytes());
    }
    packet.splice(156..156, 1_u32.to_le_bytes());
    let geometry = packet.len();
    for value in [1_u32, 3, 3, 1] {
        packet.extend(value.to_le_bytes());
    }
    for value in [
        -1_f32, -1., 0.4, 1., -1., 0.4, 0., 1., 0.4, 0., 0., 1., 0., 0., 1., 0., 0., 1.,
    ] {
        packet.extend(value.to_le_bytes());
    }
    for value in [0_u32, 1, 2] {
        packet.extend(value.to_le_bytes());
    }
    let uv = packet.len();
    for value in [0_f32, 0., 1., 0., 0., 1.] {
        packet.extend(value.to_le_bytes());
    }
    for value in [0_u32, 1] {
        packet.extend(value.to_le_bytes());
    }
    for value in glam::Mat4::IDENTITY
        .to_cols_array()
        .into_iter()
        .chain([1., 1., 1.])
    {
        packet.extend(value.to_le_bytes());
    }
    packet.extend(1_u32.to_le_bytes());
    let map = packet.len();
    for value in [1_u32, 7, 0, 0, 0, 0, 0, 0] {
        packet.extend(value.to_le_bytes());
    }
    let length = (packet.len() - 24) as u64;
    packet[16..24].copy_from_slice(&length.to_le_bytes());
    let frame = ScenePacket::decode(&packet).unwrap().resolve(None).unwrap();
    frame.validate(&Default::default()).unwrap();
    assert_eq!(frame.geometries[0].uv0.len(), 3);
    assert_eq!(frame.meshes[0].color_map.as_ref().unwrap().texture, 7);
    for end in 0..packet.len() {
        let mut truncated = packet[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&truncated).is_err(), "end {end}");
    }
    for (offset, value) in [
        (geometry + 12, 4_u32),
        (uv, f32::INFINITY.to_bits()),
        (map, 2),
        (map + 8, 2),
        (map + 12, 3),
        (map + 16, 3),
        (map + 20, 2),
        (map + 24, 2),
        (map + 28, 2),
    ] {
        let mut invalid = packet.clone();
        invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err(), "offset {offset}");
    }
    // A syntactically valid map still has to belong to this view.
    packet[map + 4..map + 8].copy_from_slice(&8_u32.to_le_bytes());
    assert!(ScenePacket::decode(&packet).unwrap().resolve(None).is_err());
}

#[test]
fn generated_mip_packet_checks_policy_and_full_residency_before_payload() {
    let mut packet = image_packet();
    packet[4..8].copy_from_slice(&14_u32.to_le_bytes());
    packet.splice(156..156, 0_u32.to_le_bytes());
    packet.splice(184..184, 2_u32.to_le_bytes());
    let length = (packet.len() - 24) as u64;
    packet[16..24].copy_from_slice(&length.to_le_bytes());
    let frame = ScenePacket::decode(&packet).unwrap().resolve(None).unwrap();
    assert_eq!(frame.textures[0].byte_length(), 20);
    assert_eq!(frame.textures[0].levels.len(), 1);
    for mode in [0_u32, 1, 2] {
        let mut valid = packet.clone();
        valid[184..188].copy_from_slice(&mode.to_le_bytes());
        let image = ScenePacket::decode(&valid).unwrap().resolve(None).unwrap();
        assert_eq!(
            image.textures[0].byte_length(),
            if mode == 0 { 16 } else { 20 }
        );
    }
    let mut oversized = packet.clone();
    oversized[168..172].copy_from_slice(&4096_u32.to_le_bytes());
    oversized[172..176].copy_from_slice(&4096_u32.to_le_bytes());
    assert!(
        matches!(ScenePacket::decode(&oversized), Err(e) if e == "texture residency budget exceeded")
    );
    for (offset, value) in [(184, 3_u32), (180, 2), (168, 4096), (172, 4096)] {
        let mut invalid = packet.clone();
        invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err());
    }
    for end in 0..packet.len() {
        let mut truncated = packet[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&truncated).is_err());
    }
}
