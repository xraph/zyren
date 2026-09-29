use zyren_runtime::{renderer::Renderer, scene::Frame};
use serde_json::json;

fn edge_frame(samples: u32, alpha: f32) -> Frame {
    serde_json::from_value(json!({
        "version": 1, "view_projection": glam::Mat4::IDENTITY.to_cols_array(),
        "background": [0,0,0], "background_alpha": 0,
        "light_direction": [0,0,1], "ambient": 0,
        "color_pipeline": {"tone_mapping": 0, "exposure": 1, "sample_count": samples},
        "geometries": [{"id":1, "positions":[[-0.72,-0.69,0.5],[0.77,-0.65,0.5],[0.01,0.83,0.5]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]], "indices":[0,1,2]}],
        "meshes": [{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),
            "color":[1,1,1],"unlit":true,"alpha_mode":2,"opacity":alpha,"depth_write":false}]
    }))
    .unwrap()
}

#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn multisampling_resolves_coverage_before_unassociating_color() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let single = renderer.render(&edge_frame(1, 1.), 31, 31).unwrap();
    assert!(single.chunks_exact(4).all(|p| p[3] == 0 || p[3] == 255));
    for alpha in [1., 0.25] {
        let mut f = edge_frame(4, alpha);
        f.geometries.clear();
        let pixels = renderer.render(&f, 31, 31).unwrap();
        let maximum = (255. * alpha).round() as u8;
        let edges: Vec<_> = pixels
            .chunks_exact(4)
            .filter(|p| p[3] > 0 && p[3] < maximum)
            .collect();
        assert!(
            edges.len() > 20,
            "multisampling must produce fractional edge coverage"
        );
        assert!(
            edges.iter().all(|p| p[..3].iter().all(|v| *v >= 253)),
            "straight white must retain its color at fractional coverage"
        );
    }
    // A different size and sample count must rebuild both color and depth.
    let mut f = edge_frame(4, 1.);
    f.geometries.clear();
    renderer.render(&f, 47, 29).unwrap();
    assert!(
        renderer
            .render(&f, 2049, 1024)
            .unwrap_err()
            .contains("Multisample color exceeds")
    );
    for invalid in [0, 2, 3, 8] {
        f.color_pipeline.as_mut().unwrap().sample_count = invalid;
        assert!(renderer.render(&f, 31, 31).is_err());
    }
    f.color_pipeline.as_mut().unwrap().sample_count = 1;
    let again = renderer.render(&f, 31, 31).unwrap();
    assert_eq!(again, single);
}

fn frame(alpha: f32, exposure: f32, curve: u32) -> Frame {
    serde_json::from_value(json!({"version":1,
        "view_projection":glam::camera::rh::proj::directx::perspective(1.0,1.0,0.1,100.0).to_cols_array(),
        "background":[0,0,0], "background_alpha": if alpha < 1. {0.} else {1.},
        "light_direction":[0,0,1],"ambient":0,
        "color_pipeline":{"tone_mapping":curve,"exposure":exposure},
        "geometries":[{"id":1,"positions":[[-2,-2,-2],[2,-2,-2],[0,2,-2]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),
            "color":[0,0,0],"unlit":false, "alpha_mode":2,"opacity":alpha,"depth_write":false,
            "pbr":{"metallic":0,"roughness":1,"emissive":[0.25,2,8]}}]
    })).unwrap()
}
fn pixel(renderer: &mut Renderer, frame: &Frame) -> [u8; 4] {
    let pixels = renderer.render(frame, 31, 31).unwrap();
    pixels[1920..1924].try_into().unwrap()
}
fn close(actual: [u8; 4], expected: [u8; 4]) {
    assert!(
        actual.iter().zip(expected).all(|(a, b)| a.abs_diff(b) <= 2),
        "{actual:?} vs {expected:?}"
    );
}
#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn hdr_exposure_precedes_tone_mapping_without_clipping_bright_channels() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = frame(1., 1., 1);
    close(pixel(&mut renderer, &f), [124, 213, 242, 255]);
    f.geometries.clear();
    f.color_pipeline.as_mut().unwrap().exposure = 0.25;
    f.color_pipeline.as_mut().unwrap().tone_mapping = 0;
    close(pixel(&mut renderer, &f), [71, 188, 255, 255]);
    f.color_pipeline.as_mut().unwrap().exposure = 0.;
    f.color_pipeline.as_mut().unwrap().tone_mapping = 1;
    close(pixel(&mut renderer, &f), [0, 0, 0, 255]);
}
#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn hdr_unassociates_before_tone_mapping_and_preserves_alpha() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    close(
        pixel(&mut renderer, &frame(0.25, 1., 1)),
        [124, 213, 242, 64],
    );
}

#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn aces_matches_reference_colored_patch() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    close(
        pixel(&mut renderer, &frame(1., 1., 2)),
        [226, 242, 254, 255],
    );
}

#[test]
#[ignore = "requires native Metal, Vulkan or DX12"]
fn transparent_light_combines_before_the_terminal_curve() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = frame(1., 1., 1);
    f.meshes[0].pbr.as_mut().unwrap().emissive = [2.; 3];
    f.meshes[0].alpha_mode = 0;
    let mut front = f.meshes[0].clone();
    front.pbr.as_mut().unwrap().emissive = [0.; 3];
    front.opacity = 0.5;
    front.alpha_mode = 2;
    front.model = glam::Mat4::from_translation(glam::Vec3::new(0., 0., 0.1)).to_cols_array();
    f.meshes.push(front);
    // 2 * 0.5 = 1 linear, then Reinhard produces 0.5 linear / 188 sRGB.
    close(pixel(&mut renderer, &f), [188, 188, 188, 255]);
}

#[test]
fn color_packets_reject_unknown_curves_nonfinite_exposure_and_truncation() {
    use zyren_runtime::scene_packet::ScenePacket;
    let mut body = Vec::new();
    body.extend(1u64.to_le_bytes());
    body.extend(0u64.to_le_bytes());
    body.extend([0u8; 16]);
    for v in glam::Mat4::IDENTITY.to_cols_array() {
        body.extend(v.to_le_bytes());
    }
    for v in [0f32, 0., 0., 0., 0., 1., 0., 1.] {
        body.extend(v.to_le_bytes());
    }
    body.extend([0u8; 8]); // Empty punctual and hemisphere tables.
    let curve = 24 + body.len();
    body.extend(1u32.to_le_bytes());
    body.extend(0.25f32.to_le_bytes());
    body.extend([0u8; 12]); // Retained images, uploads and patches.
    let mut packet = Vec::new();
    packet.extend(2u32.to_le_bytes());
    packet.extend(21u32.to_le_bytes());
    packet.extend(1u64.to_le_bytes());
    packet.extend((body.len() as u64).to_le_bytes());
    packet.extend(body);
    let frame = ScenePacket::decode(&packet).unwrap().resolve(None).unwrap();
    assert_eq!(frame.color_pipeline.unwrap().exposure, 0.25);
    for length in 0..packet.len() {
        let mut short = packet[..length].to_vec();
        if length >= 24 {
            short[16..24].copy_from_slice(&((length - 24) as u64).to_le_bytes());
        }
        assert!(ScenePacket::decode(&short).is_err());
    }
    for (offset, bits) in [
        (curve, 3u32),
        (curve + 4, (-1f32).to_bits()),
        (curve + 4, f32::INFINITY.to_bits()),
        (curve + 4, 1e7f32.to_bits()),
    ] {
        let mut invalid = packet.clone();
        invalid[offset..offset + 4].copy_from_slice(&bits.to_le_bytes());
        assert!(ScenePacket::decode(&invalid).is_err());
    }
}

#[test]
fn multisample_packet_checks_counts_and_truncation() {
    use zyren_runtime::scene_packet::ScenePacket;
    let mut packet = Vec::new();
    packet.extend(2u32.to_le_bytes());
    packet.extend(28u32.to_le_bytes());
    packet.extend(1u64.to_le_bytes());
    packet.extend(0u64.to_le_bytes());
    packet.extend(1u64.to_le_bytes());
    packet.extend(0u64.to_le_bytes());
    packet.extend([0u8; 16]);
    for v in glam::Mat4::IDENTITY.to_cols_array() {
        packet.extend(v.to_le_bytes());
    }
    for v in [0f32, 0., 0., 0., 0., 1., 0., 1.] {
        packet.extend(v.to_le_bytes());
    }
    packet.extend([0u8; 8]);
    packet.extend(1u32.to_le_bytes());
    packet.extend(0u32.to_le_bytes());
    packet.extend(1f32.to_le_bytes());
    let count = packet.len();
    packet.extend(4u32.to_le_bytes());
    packet.extend(0u32.to_le_bytes());
    for v in [0f32, 0., -1.] {
        packet.extend(v.to_le_bytes());
    }
    // Empty image, geometry patch, instance and deformation tables.
    packet.extend([0u8; 32]);
    let len = (packet.len() - 24) as u64;
    packet[16..24].copy_from_slice(&len.to_le_bytes());
    let f = ScenePacket::decode(&packet).unwrap().resolve(None).unwrap();
    assert_eq!(f.sample_count(), 4);
    for samples in [0u32, 2, 3, 8] {
        let mut p = packet.clone();
        p[count..count + 4].copy_from_slice(&samples.to_le_bytes());
        assert!(ScenePacket::decode(&p).is_err());
    }
    for n in 24..packet.len() {
        let mut p = packet[..n].to_vec();
        p[16..24].copy_from_slice(&((n - 24) as u64).to_le_bytes());
        assert!(ScenePacket::decode(&p).is_err());
    }
}
