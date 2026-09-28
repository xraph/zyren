use gpu3d_runtime::{renderer::Renderer, scene::Frame};
use serde_json::{Value, json};

fn frame(metallic: f32, roughness: f32, lights: Value) -> Frame {
    serde_json::from_value(json!({
        "version":1,
        "view_projection":glam::camera::rh::proj::directx::perspective(1.0,1.0,0.1,100.0).to_cols_array(),
        "background":[0,0,0],"light_direction":[0,0,1],"ambient":1,
        "lights":lights,
        "geometries":[{"id":1,"positions":[[-2,-2,-2],[2,-2,-2],[0,2,-2]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),
            "color":[0.5,0.5,0.5],"unlit":false,
            "pbr":{"metallic":metallic,"roughness":roughness,"emissive":[0,0,0]}}]
    }))
    .expect("the native scene accepts standard material and punctual lights")
}
fn light(kind: u32, intensity: f32, range: f32) -> Value {
    json!({"kind":kind,"color":[1,1,1],"intensity":intensity,
        "position":[0,0,0],"direction":[0,0,-1],"range":range,
        "inner_cos":1,"outer_cos":0.70710677})
}
fn pixel(renderer: &mut Renderer, frame: &Frame) -> [u8; 4] {
    let bytes = renderer.render(frame, 31, 31).unwrap();
    bytes[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4]
        .try_into()
        .unwrap()
}
fn gray(pixel: [u8; 4], expected: u8) {
    for value in &pixel[..3] {
        assert!(value.abs_diff(expected) <= 2, "{pixel:?} vs {expected}");
    }
    assert_eq!(pixel[3], 255);
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn direct_brdf_matches_normal_incidence_reference_and_has_no_ambient_energy() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut unlit = frame(0., 1., json!([]));
    gray(pixel(&mut renderer, &unlit), 0);
    unlit.geometries.clear();
    // At N=V=L and roughness=1: diffuse=.5*.96/pi, specular=.04/(4*pi).
    let mut dielectric = frame(0., 1., json!([light(0, 1., 0.)]));
    dielectric.geometries.clear();
    gray(pixel(&mut renderer, &dielectric), 110);
    let mut metal = frame(1., 1., json!([light(0, 1., 0.)]));
    metal.geometries.clear();
    // A .5 metal has only .5/(4*pi) at normal incidence.
    gray(pixel(&mut renderer, &metal), 56);
    let mut mixture = frame(0.5, 1., json!([light(0, 1., 0.)]));
    mixture.geometries.clear();
    // Half dielectric, half metal radiance: (.5*.96/pi + .54/(4*pi))/2.
    gray(pixel(&mut renderer, &mixture), 88);
    metal.meshes[0].color = [0.; 3];
    gray(pixel(&mut renderer, &metal), 0);
    unlit.meshes[0].pbr.as_mut().unwrap().emissive = [0.25; 3];
    gray(pixel(&mut renderer, &unlit), 137);
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn punctual_lights_use_inverse_square_range_and_spot_cones() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut point = frame(0., 1., json!([light(1, 4., 0.)]));
    gray(pixel(&mut renderer, &point), 110);
    point.geometries.clear();
    point.lights[0].position = [0., 0., 2.];
    gray(pixel(&mut renderer, &point), 56);
    point.lights[0].range = 4.;
    gray(pixel(&mut renderer, &point), 0);
    let mut spot = frame(0., 1., json!([light(2, 4., 0.)]));
    spot.geometries.clear();
    gray(pixel(&mut renderer, &spot), 110);
    spot.lights[0].direction = [1., 0., 0.];
    gray(pixel(&mut renderer, &spot), 0);
    // Small distinct angles can have identical float32 cosines. The cone's
    // centre must still receive full intensity at the representable limit.
    spot.lights[0].direction = [0., 0., -1.];
    spot.lights[0].inner_cos = 1.;
    spot.lights[0].outer_cos = 1.;
    gray(pixel(&mut renderer, &spot), 110);
}

#[test]
fn malformed_standard_materials_and_light_admission_are_rejected() {
    let mut candidate = frame(0., 1., json!([]));
    for invalid in [-0.1, 1.1, f32::NAN, f32::INFINITY] {
        candidate.meshes[0].pbr.as_mut().unwrap().metallic = invalid;
        assert!(candidate.validate(&Default::default()).is_err());
    }
    candidate = frame(0., 1., json!([light(0, 1., 0.)]));
    candidate.lights[0].direction = [0.; 3];
    assert!(candidate.validate(&Default::default()).is_err());
    candidate = frame(0., 1., json!(vec![light(1, 1., 0.); 17]));
    assert!(candidate.validate(&Default::default()).is_err());
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn roughness_broadens_specular_reflection_and_zero_stays_finite() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut metal = frame(1., 0.1, json!([light(0, 1., 0.)]));
    metal.lights[0].direction = [0.6, 0., -0.8];
    let narrow = pixel(&mut renderer, &metal)[0];
    metal.geometries.clear();
    metal.meshes[0].pbr.as_mut().unwrap().roughness = 0.6;
    let broad = pixel(&mut renderer, &metal)[0];
    assert!(
        broad > narrow + 30,
        "off-specular probe: {narrow} -> {broad}"
    );
    metal.meshes[0].pbr.as_mut().unwrap().roughness = 0.;
    metal.lights[0].direction = [0., 0., -1.];
    gray(pixel(&mut renderer, &metal), 255);
}

#[test]
fn light_packets_reject_truncation_and_oversized_tables() {
    use gpu3d_runtime::scene_packet::ScenePacket;
    let mut body = Vec::new();
    body.extend(1u64.to_le_bytes());
    body.extend(0u64.to_le_bytes());
    body.extend([0u8; 16]);
    for value in glam::Mat4::IDENTITY.to_cols_array() {
        body.extend(value.to_le_bytes());
    }
    for value in [0f32, 0., 0., 0., 0., 1., 0., 1.] {
        body.extend(value.to_le_bytes());
    }
    let count_offset = 24 + body.len();
    body.extend(1u32.to_le_bytes());
    body.extend(0u32.to_le_bytes());
    for value in [1f32, 1., 1., 1., 0., 0., 0., 0., 0., -1., 0., 1., 0.] {
        body.extend(value.to_le_bytes());
    }
    body.extend([0u8; 12]);
    let mut packet = Vec::new();
    packet.extend(2u32.to_le_bytes());
    packet.extend(19u32.to_le_bytes());
    packet.extend(1u64.to_le_bytes());
    packet.extend((body.len() as u64).to_le_bytes());
    packet.extend(body);
    assert_eq!(
        ScenePacket::decode(&packet)
            .unwrap()
            .resolve(None)
            .unwrap()
            .lights
            .len(),
        1
    );
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
    packet[count_offset..count_offset + 4].copy_from_slice(&17u32.to_le_bytes());
    assert!(ScenePacket::decode(&packet).is_err());
}
