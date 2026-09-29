use zyren_runtime::{renderer::Renderer, scene::Frame};
use serde_json::json;
fn frame(map_name: &str, texel: [u8; 4], linear: bool) -> Frame {
    let mut value = json!({"version":1,
        "view_projection":glam::camera::rh::proj::directx::perspective(1.0,1.0,0.1,100.0).to_cols_array(),
        "background":[0,0,0],"light_direction":[0,0,1],"ambient":0,
        "lights":[{"kind":0,"color":[1,1,1],"intensity":1,"position":[0,0,0],
            "direction":[0,0,-1],"range":0,"inner_cos":1,"outer_cos":0}],
        "geometries":[{"id":1,"positions":[[-2,-2,-2],[2,-2,-2],[0,2,-2]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2],
            "uv0":[[0,0],[1,0],[0.5,1]],"tangents":[[1,0,0,1],[1,0,0,1],[1,0,0,1]]}],
        "meshes":[{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),
            "color":[0.5,0.5,0.5],"unlit":false,
            "pbr":{"metallic":0,"roughness":1,"emissive":[0,0,0]}}],
        "textures":[{"id":1,"width":1,"height":1,"format":if linear {0}else{1},"levels":[texel]}]
    });
    value["meshes"][0]["pbr"][map_name] = json!({"texture":1,"uv_set":0,"sampler":[0,0,0,0,0]});
    serde_json::from_value(value).expect("native material texture profile")
}
fn pixel(renderer: &mut Renderer, frame: &Frame) -> [u8; 4] {
    let image = renderer.render(frame, 31, 31).unwrap();
    image[1920..1924].try_into().unwrap()
}
fn close(a: [u8; 4], b: [u8; 4]) {
    assert!(
        a.iter().zip(b).all(|(a, b)| a.abs_diff(b) <= 2),
        "{a:?} vs {b:?}"
    );
}
#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn emission_and_packed_channels_match_constant_materials() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut emission = frame("emissive_map", [64, 128, 192, 0], false);
    emission.lights.clear();
    emission.meshes[0].pbr.as_mut().unwrap().emissive = [1.; 3];
    close(pixel(&mut renderer, &emission), [64, 128, 192, 255]);
    drop(renderer);
    for texel in [[0, 255, 255, 0], [255, 128, 0, 255], [0, 64, 128, 255]] {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let mut packed = frame("metallic_roughness_map", texel, true);
        packed.meshes[0].pbr.as_mut().unwrap().metallic = 1.;
        let actual = pixel(&mut renderer, &packed);
        packed.geometries.clear();
        packed.textures.clear();
        let pbr = packed.meshes[0].pbr.as_mut().unwrap();
        pbr.metallic_roughness_map = None;
        pbr.metallic = f32::from(texel[2]) / 255.;
        pbr.roughness = f32::from(texel[1]) / 255.;
        close(actual, pixel(&mut renderer, &packed));
    }
}
#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn tangent_normals_preserve_handedness_and_mirrored_transforms() {
    for (handedness, scale) in [(1., 1.), (-1., 1.), (1., -2.)] {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let mut mapped = frame("normal_map", [128, 204, 230, 255], true);
        mapped.lights[0].direction = [0., -0.6, -0.8];
        mapped.meshes[0].model =
            glam::Mat4::from_scale(glam::Vec3::new(1., scale, 1.)).to_cols_array();
        for t in &mut mapped.geometries[0].tangents {
            t[3] = handedness;
        }
        let actual = pixel(&mut renderer, &mapped);
        mapped.textures.clear();
        mapped.geometries[0].id = 2;
        mapped.meshes[0].geometry = 2;
        mapped.meshes[0].model = glam::Mat4::IDENTITY.to_cols_array();
        mapped.meshes[0].pbr.as_mut().unwrap().normal_map = None;
        mapped.geometries[0].normals =
            vec![[1. / 255., 0.6 * handedness * scale.signum(), 205. / 255.]; 3];
        close(actual, pixel(&mut renderer, &mapped));
    }
}
#[test]
fn malformed_tangent_handedness_is_rejected() {
    let mut value = frame("normal_map", [128, 128, 255, 255], true);
    value.geometries[0].tangents[0][3] = 0.;
    assert!(value.validate(&Default::default()).is_err());
}

#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn invalid_data_formats_and_missing_uvs_leave_the_device_usable() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let valid = frame("normal_map", [128, 128, 255, 255], true);
    let mut invalid = valid.clone();
    invalid.textures[0].format = 1;
    assert!(
        renderer
            .render(&invalid, 31, 31)
            .unwrap_err()
            .contains("linear storage")
    );
    invalid = valid.clone();
    invalid.geometries[0].uv0.clear();
    assert!(
        renderer
            .render(&invalid, 31, 31)
            .unwrap_err()
            .contains("missing UV")
    );
    close(pixel(&mut renderer, &valid), [110, 110, 110, 255]);
}

#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn occlusion_only_modulates_explicit_hemisphere_light() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut ambient = frame("occlusion_map", [0, 255, 255, 255], true);
    ambient.lights.clear();
    ambient.hemispheres = vec![
        serde_json::from_value(json!({"sky_color":[1,1,1],
        "ground_color":[0,0,0],"direction":[0,0,1],"intensity":1}))
        .unwrap(),
    ];
    close(pixel(&mut renderer, &ambient), [0, 0, 0, 255]);
    ambient.geometries.clear();
    ambient.textures.clear();
    ambient.meshes[0].pbr.as_mut().unwrap().occlusion_strength = 0.;
    close(pixel(&mut renderer, &ambient), [109, 109, 109, 255]);
    ambient.meshes[0].pbr.as_mut().unwrap().occlusion_strength = 1.;
    ambient.meshes[0].pbr.as_mut().unwrap().emissive = [0.25; 3];
    close(pixel(&mut renderer, &ambient), [137, 137, 137, 255]);
    ambient.meshes[0].pbr.as_mut().unwrap().emissive = [0.; 3];
    ambient.lights = frame("occlusion_map", [0, 255, 255, 255], true).lights;
    close(pixel(&mut renderer, &ambient), [110, 110, 110, 255]);
    ambient.lights.clear();
    ambient.hemispheres[0].direction = [0., 0., -1.];
    ambient.meshes[0].pbr.as_mut().unwrap().occlusion_strength = 0.;
    close(pixel(&mut renderer, &ambient), [0, 0, 0, 255]);
}

#[test]
fn material_texture_packets_reject_truncation_flags_and_invalid_tangents() {
    use zyren_runtime::scene_packet::ScenePacket;
    fn u32s(bytes: &mut Vec<u8>, values: &[u32]) {
        for v in values {
            bytes.extend(v.to_le_bytes());
        }
    }
    fn floats(bytes: &mut Vec<u8>, values: &[f32]) {
        for v in values {
            bytes.extend(v.to_le_bytes());
        }
    }
    let mut body = Vec::new();
    body.extend(1u64.to_le_bytes());
    body.extend(0u64.to_le_bytes());
    u32s(&mut body, &[1, 1, 1, 1]);
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(&mut body, &[0., 0., 0., 0., 0., 1., 0., 1.]);
    u32s(&mut body, &[0]);
    let hemisphere_count = 24 + body.len();
    u32s(&mut body, &[1]);
    floats(&mut body, &[1., 1., 1., 0., 0., 0., 0., 1., 0., 1.]);
    u32s(&mut body, &[1, 1, 0, 1, 1]);
    u32s(&mut body, &[1, 1, 1, 0, 1, 0, 4]);
    body.extend([128, 128, 255, 255]);
    u32s(&mut body, &[1, 3, 3, 9, 0]);
    floats(&mut body, &[-1., -1., 0., 1., -1., 0., 0., 1., 0.]);
    floats(&mut body, &[0., 0., 1., 0., 0., 1., 0., 0., 1.]);
    u32s(&mut body, &[0, 1, 2]);
    floats(&mut body, &[0., 0., 1., 0., 0.5, 1.]);
    let tangent_w = 24 + body.len() + 12;
    floats(&mut body, &[1., 0., 0., 1., 1., 0., 0., 1., 1., 0., 0., 1.]);
    u32s(&mut body, &[0, 1]);
    floats(&mut body, &glam::Mat4::IDENTITY.to_cols_array());
    floats(&mut body, &[0.5, 0.5, 0.5]);
    u32s(&mut body, &[0, 0, 0]);
    floats(&mut body, &[1., 0.5]);
    u32s(&mut body, &[1, 1, 0, 0]);
    floats(&mut body, &[1.]);
    u32s(&mut body, &[0, 0, 0, 1]);
    floats(&mut body, &[0., 1., 0., 0., 0., 1., 1.]);
    let map_flag = 24 + body.len();
    for _ in 0..4 {
        u32s(&mut body, &[1, 1, 0, 0, 0, 0, 0, 0]);
    }
    let mut packet = Vec::new();
    u32s(&mut packet, &[2, 20]);
    packet.extend(1u64.to_le_bytes());
    packet.extend((body.len() as u64).to_le_bytes());
    packet.extend(body);
    let frame = ScenePacket::decode(&packet).unwrap().resolve(None).unwrap();
    assert_eq!(frame.meshes[0].texture_maps().count(), 4);
    assert_eq!(frame.geometries[0].tangents.len(), 3);
    assert_eq!(frame.hemispheres.len(), 1);
    for length in 0..packet.len() {
        let mut truncated = packet[..length].to_vec();
        if length >= 24 {
            truncated[16..24].copy_from_slice(&((length - 24) as u64).to_le_bytes());
        }
        assert!(
            ScenePacket::decode(&truncated).is_err(),
            "accepted truncation at {length}"
        );
    }
    for (offset, value) in [(hemisphere_count, 5u32), (tangent_w, 0), (map_flag, 2)] {
        let mut invalid = packet.clone();
        invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
        assert!(
            ScenePacket::decode(&invalid).is_err(),
            "accepted invalid field at {offset}"
        );
    }
}
