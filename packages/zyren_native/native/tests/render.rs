use serde_json::{Value, json};
use zyren_runtime::{renderer::Renderer, scene::Frame};

fn frame_json() -> Value {
    let identity = glam::Mat4::IDENTITY.to_cols_array();
    json!({
        "version":1,"view_projection":identity,"background":[0,0,0],
        "light_direction":[0,0,1],"ambient":0.2,
        "geometries":[{"id":1,"positions":[[-0.8,-0.8,0.4],[0.8,-0.8,0.4],[0,0.8,0.4]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":identity,"color":[1,0,0],"unlit":true}]
    })
}

#[test]
fn rejects_invalid_scenes_before_upload() {
    let mut value = frame_json();
    value["geometries"][0]["indices"] = json!([0, 1, 99]);
    let frame: Frame = serde_json::from_value(value).unwrap();
    assert!(frame.validate(&Default::default()).is_err());
    let mut value = frame_json();
    value["meshes"][0]["model"] = json!(vec![0; 16]);
    let frame: Frame = serde_json::from_value(value).unwrap();
    assert!(frame.validate(&Default::default()).is_err());
    let mut value = frame_json();
    value["version"] = json!(2);
    let frame: Frame = serde_json::from_value(value).unwrap();
    assert!(frame.validate(&Default::default()).is_err());
    assert!(zyren_runtime::scene::pixel_len(0, 64).is_err());
    assert!(zyren_runtime::scene::pixel_len(4097, 64).is_err());
}

#[test]
fn ffi_rejects_disposed_handles_and_null_buffers() {
    assert_eq!(zyren_runtime::fg_destroy(u64::MAX), 0);
    let len = unsafe { zyren_runtime::fg_last_error(std::ptr::null_mut(), 0) };
    assert!(len > 0);
    assert_eq!(
        unsafe {
            zyren_runtime::fg_render(0, std::ptr::null(), 0, 32, 32, std::ptr::null_mut(), 0)
        },
        0
    );
}

/// Explicitly enabled on a host with a GPU. Missing adapters fail this test.
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn native_gpu_pixels_depth_resize_and_cache() {
    let mut renderer = pollster::block_on(Renderer::new()).expect("native adapter");
    eprintln!(
        "Native adapter: {} ({:?})",
        renderer.adapter_name, renderer.backend
    );
    assert!(matches!(
        renderer.backend,
        wgpu::Backend::Metal | wgpu::Backend::Vulkan | wgpu::Backend::Dx12
    ));
    let mut value = frame_json();
    let mut behind = value["meshes"][0].clone();
    behind["color"] = json!([0, 1, 0]);
    behind["model"][14] = json!(0.2);
    value["meshes"].as_array_mut().unwrap().push(behind);
    let frame: Frame = serde_json::from_value(value.clone()).unwrap();
    let pixels = renderer.render(&frame, 63, 47).unwrap();
    assert_eq!(pixels.len(), 63 * 47 * 4);
    let center = (23 * 63 + 31) * 4;
    assert_eq!(
        &pixels[center..center + 4],
        &[255, 0, 0, 255],
        "near red triangle must occlude later green triangle"
    );
    assert_eq!(&pixels[..4], &[0, 0, 0, 255]);
    value["geometries"] = json!([]);
    let frame: Frame = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(
        renderer.render(&frame, 127, 65).unwrap().len(),
        127 * 65 * 4
    );
    value["meshes"] = json!([]);
    let empty: Frame = serde_json::from_value(value).unwrap();
    assert!(
        renderer
            .render(&empty, 9, 7)
            .unwrap()
            .chunks_exact(4)
            .all(|p| p == [0, 0, 0, 255])
    );
    assert_eq!(renderer.render(&empty, 4096, 1).unwrap().len(), 4096 * 4);
    let handle = zyren_runtime::fg_create();
    assert_ne!(handle, 0);
    zyren_runtime::fg_finalize(handle as usize as *mut std::ffi::c_void);
    assert_eq!(zyren_runtime::fg_destroy(handle), 0);
    assert!(
        renderer.render(&frame, 9, 7).is_err(),
        "unused geometry must be released"
    );
}

#[test]
fn json_material_defaults_and_validation_match_binary_contract() {
    let original = frame_json();
    let legacy: Frame = serde_json::from_value(original.clone()).unwrap();
    assert!(legacy.meshes[0].writes_depth());
    assert_eq!(legacy.meshes[0].opacity, 1.);
    let mut glass = original.clone();
    glass["meshes"][0]["alpha_mode"] = json!(2);
    let frame: Frame = serde_json::from_value(glass.clone()).unwrap();
    assert!(!frame.meshes[0].writes_depth());
    glass["meshes"][0]["depth_write"] = json!(true);
    let frame: Frame = serde_json::from_value(glass).unwrap();
    assert!(frame.meshes[0].writes_depth());
    for (field, value) in [
        ("alpha_mode", json!(3)),
        ("opacity", json!(-0.1)),
        ("alpha_cutoff", json!(-0.1)),
    ] {
        let mut invalid = original.clone();
        invalid["meshes"][0][field] = value;
        let frame: Frame = serde_json::from_value(invalid).unwrap();
        assert!(frame.validate(&Default::default()).is_err());
    }
    for cutoff in [1.1, f32::MAX] {
        let mut masked = original.clone();
        masked["meshes"][0]["alpha_mode"] = json!(1);
        masked["meshes"][0]["alpha_cutoff"] = json!(cutoff);
        let frame: Frame = serde_json::from_value(masked).unwrap();
        assert!(frame.validate(&Default::default()).is_ok());
    }
}
