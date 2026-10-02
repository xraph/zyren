use serde_json::{Value, json};
use zyren_runtime::scene_packet::ScenePacket;

const FIXTURE: &[u8] = include_bytes!("fixtures/integrated-scene-v36.bin");
const MESH: &[u8] = b"{\"material_shader\"";
const SETTINGS: &[u8] = b"{\"enabled\"";
fn framing(data: &mut [u8]) {
    let size = (data.len() - 24) as u64;
    data[16..24].copy_from_slice(&size.to_le_bytes());
}
fn edit(tag: &[u8], mutate: impl FnOnce(&mut Value)) -> Vec<u8> {
    let mut data = FIXTURE.to_vec();
    let start = data.windows(tag.len()).position(|v| v == tag).unwrap();
    let length = u32::from_le_bytes(data[start - 4..start].try_into().unwrap()) as usize;
    let mut value: Value = serde_json::from_slice(&data[start..start + length]).unwrap();
    mutate(&mut value);
    let encoded = serde_json::to_vec(&value).unwrap();
    let mut replacement = (encoded.len() as u32).to_le_bytes().to_vec();
    replacement.extend(encoded);
    data.splice(start - 4..start + length, replacement);
    framing(&mut data);
    data
}
fn valid(data: &[u8]) -> bool {
    ScenePacket::decode(data)
        .and_then(|p| p.resolve(None))
        .is_ok()
}
#[test]
fn dart_fixture_combines_core_optics_with_geospatial_state() {
    let frame = ScenePacket::decode(FIXTURE).unwrap().resolve(None).unwrap();
    assert_eq!(frame.settings.depth_strategy, 1);
    assert_eq!(frame.settings.camera_origin[0], 6378137.);
    assert_eq!(frame.settings.tone_mapping, 1);
    assert_eq!(frame.settings.outline.as_ref().unwrap().width, 2);
    let mesh = &frame.meshes[0];
    assert_eq!(mesh.clipping_planes, [[1., 0., 0., -0.25]]);
    assert_eq!(mesh.coverage, [0., 0.5]);
    assert!(mesh.outlined && mesh.reversed_depth);
    let pbr = mesh.pbr.as_ref().unwrap();
    assert_eq!(pbr.normal_scale, 0.5);
    assert_eq!(pbr.normal_scale_y, -0.75);
    assert!(pbr.physical.is_some());
    assert_eq!(pbr.optical[0], 0.5);
}
#[test]
fn extension_packets_reject_every_truncation_even_with_correct_outer_length() {
    for end in 24..FIXTURE.len() {
        let mut data = FIXTURE[..end].to_vec();
        framing(&mut data);
        assert!(!valid(&data), "accepted {end}");
    }
}
#[test]
fn screen_settings_bound_effects_depth_samples_and_output() {
    for (name, value) in [
        ("sample_count", json!(2)),
        ("depth_strategy", json!(2)),
        ("spatial_antialiasing", json!(2)),
        ("tone_mapping", json!(7)),
        ("exposure", json!(-1)),
        ("exposure", json!(1e40)),
        ("background_alpha", json!(1.1)),
        ("camera_origin", json!([0, 0])),
        ("enabled", json!(2)),
        ("effects", json!(vec![[1, 1, 1, 1]; 33])),
    ] {
        assert!(
            !valid(&edit(SETTINGS, |v| v[name] = value)),
            "accepted {name}"
        );
    }
    for samples in [1, 4] {
        assert!(valid(
            &edit(SETTINGS, |v| v["sample_count"] = json!(samples))
        ));
    }
    assert!(!valid(&edit(SETTINGS, |v| {
        v["sample_count"] = json!(4);
        v["enabled"] = json!(false);
    })));
}
#[test]
fn environment_extensions_bound_layout_intensity_and_owner_keys() {
    assert!(valid(&edit(
        SETTINGS,
        |v| v["environment"] =
            json!({"keys":[[1,1,1,1],[1,1,2,1],[1,1,3,1]],"intensity":1,"rotation":0})
    )));
    for environment in [
        json!({"keys":[],"intensity":1,"rotation":0}),
        json!({"keys":vec![[1,1,1,1];3],"intensity":-1,"rotation":0}),
    ] {
        assert!(!valid(&edit(SETTINGS, |v| v["environment"] = environment)));
    }
}
#[test]
fn builtin_effect_extensions_validate_bloom_and_outline() {
    for bloom in [
        json!({"intensity":1,"threshold":1,"soft_knee":0.5,"scatter":0.5,"levels":0}),
        json!({"intensity":-1,"threshold":1,"soft_knee":0.5,"scatter":0.5,"levels":3}),
    ] {
        assert!(!valid(&edit(SETTINGS, |v| v["bloom"] = bloom)));
    }
    for outline in [
        json!({"color":[1,0,0,1],"width":0}),
        json!({"color":[1,0,0,2],"width":2}),
    ] {
        assert!(!valid(&edit(SETTINGS, |v| v["outline"] = outline)));
    }
}
#[test]
fn section_extensions_require_normalized_planes_and_builtin_materials() {
    for planes in [
        json!([[0, 0, 0, 0]]),
        json!([[2, 0, 0, 0]]),
        json!(vec![[1, 0, 0, 0]; 7]),
    ] {
        assert!(!valid(&edit(MESH, |v| v["clipping_planes"] = planes)));
    }
    assert!(!valid(
        &edit(MESH, |v| v["material_shader"] = json!([1, 1, 1, 1]))
    ));
}
#[test]
fn mesh_extensions_bound_coverage_normal_scale_and_unknown_fields() {
    for coverage in [json!([-0.1, 1]), json!([0, 1.1]), json!([0.8, 0.2])] {
        assert!(!valid(&edit(MESH, |v| v["coverage"] = coverage)));
    }
    assert!(!valid(&edit(MESH, |v| v["normal_scale_y"] = json!(1e40))));
    assert!(!valid(&edit(MESH, |v| v["unexpected"] = json!(true))));
    for coverage in [json!([0, 0]), json!([0, 1]), json!([0.5, 1])] {
        assert!(valid(&edit(MESH, |v| v["coverage"] = coverage)));
    }
}
#[test]
fn extension_byte_lengths_are_bounded_before_allocation() {
    for (tag, limit) in [(MESH, 4096_u32), (SETTINGS, 16384)] {
        let start = FIXTURE.windows(tag.len()).position(|v| v == tag).unwrap();
        let mut data = FIXTURE.to_vec();
        data[start - 4..start].copy_from_slice(&(limit + 1).to_le_bytes());
        assert!(!valid(&data));
    }
}
