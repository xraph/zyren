use serde_json::json;
use zyren_runtime::{renderer::Renderer, scene::Frame};
fn fixture(count: usize) -> Frame {
    let identity = glam::Mat4::IDENTITY.to_cols_array();
    serde_json::from_value(json!({
        "version":1,"view_projection":identity,"background":[0,0,0],
        "light_direction":[0,0,1],"ambient":0.2,
        "geometries":[{"id":1,"positions":[[-0.8,-0.8,0.4],[0.8,-0.8,0.4],[0,0.8,0.4]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":(0..count).map(|_| json!({"geometry":1,"model":identity,"color":[1,0,0],"unlit":true})).collect::<Vec<_>>()
    })).unwrap()
}
fn profile(renderer: &mut Renderer) -> serde_json::Value {
    let reply = renderer
        .graph_command(
            &serde_json::to_vec(
                &json!({"version":1,"request":1,"command":{"operation":"frameProfile"}}),
            )
            .unwrap(),
            256 * 1024,
        )
        .unwrap();
    serde_json::from_slice::<serde_json::Value>(&reply).unwrap()["result"].clone()
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn many_mesh_preparation_sample() {
    preparation_sample(false);
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn camera_motion_preparation_sample() {
    preparation_sample(true);
}
fn preparation_sample(motion: bool) {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture(1024);
    let pixels = renderer.render(&frame, 64, 64).unwrap();
    frame.geometries.clear();
    let mut samples = Vec::new();
    let mut hashes = Vec::new();
    for step in 1..=20 {
        if motion {
            frame.view_projection[12] = step as f32 * 0.005;
        }
        let rendered = renderer.render(&frame, 64, 64).unwrap();
        if !motion {
            assert_eq!(rendered, pixels);
        }
        hashes.push(crc32fast::hash(&rendered));
        samples.push(profile(&mut renderer));
    }
    let label = if motion { "MOTION" } else { "PREPARATION" };
    println!(
        "DRAW_{label}_PIXELS {}",
        serde_json::to_string(&hashes).unwrap()
    );
    println!(
        "DRAW_{label}_SAMPLES {}",
        serde_json::to_string(&samples).unwrap()
    );
}

fn view(frame: &mut Frame, id: u64) {
    frame.binary = Some(zyren_runtime::scene_packet::ViewState {
        view: id,
        revision: 1,
        retained: [1].into_iter().collect(),
        meshes: frame.meshes.clone(),
        retained_textures: Default::default(),
        retained_instances: Default::default(),
        retained_poses: Default::default(),
    });
}
fn assert_warm(renderer: &mut Renderer, meshes: u64) -> serde_json::Value {
    let p = profile(renderer);
    assert_eq!(p["drawPreparationBuffers"], 0);
    assert_eq!(p["drawPreparationBindGroups"], 0);
    assert_eq!(p["drawUniformWriteCalls"], 0);
    assert_eq!(p["drawUniformWriteBytes"], 0);
    assert!(p["drawCacheReuses"].as_u64().unwrap() >= meshes);
    p
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn stationary_camera_material_reorder_visibility_resize_and_cleanup() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture(2);
    frame.meshes[1].color = [0., 1., 0.];
    frame.meshes[1].model[14] = 0.1;
    let initial = renderer.render(&frame, 63, 47).unwrap();
    let allocated = profile(&mut renderer);
    assert_eq!(allocated["drawPreparationBuffers"], 2);
    assert_eq!(allocated["drawPreparationBindGroups"], 2);
    assert_eq!(allocated["drawUniformWriteCalls"], 2);
    let uniform_bytes = allocated["drawCacheUniformBytes"].as_u64().unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 84 + uniform_bytes);
    frame.geometries.clear();
    assert_eq!(renderer.render(&frame, 63, 47).unwrap(), initial);
    assert_warm(&mut renderer, 2);
    frame.view_projection[12] = 0.1;
    let moved = renderer.render(&frame, 63, 47).unwrap();
    assert_ne!(moved, initial);
    let p = profile(&mut renderer);
    assert_eq!(p["drawPreparationBuffers"], 0);
    assert_eq!(p["drawPreparationBindGroups"], 0);
    assert_eq!(p["drawUniformWriteCalls"], 2);
    assert!(p["drawUniformWriteBytes"].as_u64().unwrap() < uniform_bytes);
    frame.meshes[0].color = [0., 0., 1.];
    let edited = renderer.render(&frame, 63, 47).unwrap();
    assert_ne!(edited, moved);
    let p = profile(&mut renderer);
    assert_eq!(p["drawUniformWriteCalls"], 1);
    assert!(p["drawUniformWriteBytes"].as_u64().unwrap() <= 12);
    frame.meshes.reverse();
    assert_eq!(renderer.render(&frame, 63, 47).unwrap(), edited);
    assert_eq!(profile(&mut renderer)["drawPreparationBuffers"], 0);
    frame.meshes[1].color_visible = false;
    let hidden = renderer.render(&frame, 63, 47).unwrap();
    assert_ne!(hidden, edited);
    assert_eq!(
        profile(&mut renderer)["drawCacheUniformBytes"],
        uniform_bytes / 2
    );
    frame.meshes[1].color_visible = true;
    assert_eq!(renderer.render(&frame, 63, 47).unwrap(), edited);
    assert_eq!(profile(&mut renderer)["drawPreparationBuffers"], 1);
    renderer.render(&frame, 80, 60).unwrap();
    let p = profile(&mut renderer);
    assert_eq!(p["drawPreparationBuffers"], 0);
    assert_eq!(p["drawPreparationBindGroups"], 0);
    assert_eq!(p["drawUniformWriteCalls"], 2);
    renderer.close_scene_view(0).unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 0);
    let p = profile(&mut renderer);
    assert_eq!(p["drawCacheEntries"], 0);
    assert_eq!(p["drawCacheUniformBytes"], 0);
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn more_than_eight_views_evict_cache_without_evicting_published_assets() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture(1);
    for id in 1..=10 {
        view(&mut frame, id);
        renderer.render(&frame, 31, 31).unwrap();
        frame.geometries.clear();
        let p = profile(&mut renderer);
        assert_eq!(p["drawPreparationBuffers"], 1);
        assert!(
            p["drawCacheUniformBytes"].as_u64().unwrap()
                <= 8 * p["drawUniformWriteBytes"].as_u64().unwrap()
        );
    }
    view(&mut frame, 10);
    renderer.render(&frame, 31, 31).unwrap();
    assert_warm(&mut renderer, 1);
    view(&mut frame, 1);
    let pixels = renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[255, 0, 0, 255]
    );
    assert_eq!(profile(&mut renderer)["drawPreparationBuffers"], 1);
    for id in 1..=10 {
        renderer.close_scene_view(id).unwrap();
    }
    assert_eq!(renderer.scene_resource_stats().0, 0);
    assert_eq!(profile(&mut renderer)["drawCacheEntries"], 0);
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn transmission_keeps_distinct_pass_bindings_and_rebuilds_on_target_resize() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture(2);
    frame.meshes[0].unlit = false;
    frame.meshes[0].pbr = Some(
        serde_json::from_value(json!({"metallic":0,"roughness":1,"emissive":[0.25,0,0]})).unwrap(),
    );
    frame.meshes[1].unlit = false;
    frame.meshes[1].model[14] = -0.1;
    frame.meshes[1].pbr = Some(serde_json::from_value(json!({"metallic":0,"roughness":0.1,"emissive":[0,0,0],"physical":[1.5,1,0,0,1,1,1,1,0,0,0,0,0,1,1,0],"transmission":[1,0,0,0,1,1,1,0]})).unwrap());
    let pixels = renderer.render(&frame, 31, 31).unwrap();
    let cold = profile(&mut renderer);
    assert_eq!(cold["drawPreparationBuffers"], 6); // 3 mesh pass slots + environment, lights, shadow sampling.
    assert_eq!(cold["drawPreparationBindGroups"], 3);
    assert_eq!(cold["passes"]["transmission"]["executed"], true);
    frame.geometries.clear();
    assert_eq!(renderer.render(&frame, 31, 31).unwrap(), pixels);
    assert_warm(&mut renderer, 3);
    renderer.render(&frame, 47, 35).unwrap();
    let resized = profile(&mut renderer);
    assert_eq!(resized["drawPreparationBuffers"], 0);
    assert_eq!(resized["drawPreparationBindGroups"], 2); // Main pass samples new capture targets; capture keeps its defaults.
    renderer.render(&frame, 47, 35).unwrap();
    assert_warm(&mut renderer, 3);
    renderer.close_scene_view(0).unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 0);
}
fn packet(op: u32, body: &[u8]) -> Vec<u8> {
    [
        2_u32.to_le_bytes().as_slice(),
        op.to_le_bytes().as_slice(),
        1_u64.to_le_bytes().as_slice(),
        (body.len() as u64).to_le_bytes().as_slice(),
        body,
    ]
    .concat()
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn draw_uniforms_obey_the_configured_registry_budget_and_retry() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let budget = 16 * 1024 * 1024_u64;
    renderer
        .resource_command(&packet(13, &budget.to_le_bytes()), 24)
        .unwrap();
    let descriptor = [
        (budget - 128).to_le_bytes().as_slice(),
        32_u32.to_le_bytes().as_slice(),
        0_u32.to_le_bytes().as_slice(),
    ]
    .concat();
    let reply = renderer
        .resource_command(&packet(1, &descriptor), 56)
        .unwrap();
    let allocation = reply[24..].to_vec();
    let frame = fixture(1);
    assert!(
        renderer
            .render(&frame, 31, 31)
            .unwrap_err()
            .contains("budget")
    );
    assert_eq!(renderer.scene_resource_stats().0, budget - 128);
    renderer
        .resource_command(&packet(6, &allocation), 24)
        .unwrap();
    let pixels = renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[255, 0, 0, 255]
    );
    assert_eq!(
        renderer.scene_resource_stats().0,
        84 + profile(&mut renderer)["drawCacheUniformBytes"]
            .as_u64()
            .unwrap()
    );
    renderer.close_scene_view(0).unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 0);
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn material_texture_and_sampler_generations_and_physical_layouts_invalidate_bindings() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture(1);
    frame.geometries[0].uv0 = vec![[0., 0.], [1., 0.], [0.5, 1.]];
    frame.textures = vec![
        serde_json::from_value(
            json!({"id":1,"width":1,"height":1,"format":0,"levels":[[255,0,0,255]]}),
        )
        .unwrap(),
    ];
    let map =
        serde_json::from_value(json!({"texture":1,"uv_set":0,"sampler":[0,0,0,0,0]})).unwrap();
    frame.meshes[0].unlit = false;
    frame.meshes[0].pbr = Some(serde_json::from_value(json!({"metallic":0,"roughness":1,"emissive":[1,1,1],"emissive_map":{"texture":1,"uv_set":0,"sampler":[0,0,0,0,0]},"physical":[1.5,1,0,0,1,1,1,1,0,0,0,0,0,1,1,0]})).unwrap());
    let pixels = renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[255, 0, 0, 255]
    );
    frame.geometries.clear();
    frame.textures.clear();
    assert_eq!(renderer.render(&frame, 31, 31).unwrap(), pixels);
    assert_warm(&mut renderer, 2);
    frame.meshes[0].pbr.as_mut().unwrap().physical_maps[0] = Some(map);
    renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(profile(&mut renderer)["drawPreparationBindGroups"], 1);
    renderer.render(&frame, 31, 31).unwrap();
    assert_warm(&mut renderer, 3);
    frame.meshes[0].pbr.as_mut().unwrap().physical_maps[1] =
        frame.meshes[0].pbr.as_ref().unwrap().physical_maps[0].clone();
    renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(profile(&mut renderer)["drawPreparationBindGroups"], 1);
    frame.meshes[0]
        .pbr
        .as_mut()
        .unwrap()
        .emissive_map
        .as_mut()
        .unwrap()
        .sampler[0] = 1;
    renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(profile(&mut renderer)["drawPreparationBindGroups"], 1);
    let mut replacement = fixture(1);
    replacement.geometries.clear();
    replacement.meshes[0].unlit = false;
    replacement.meshes[0].pbr = Some(serde_json::from_value(json!({"metallic":0,"roughness":1,"emissive":[1,1,1],"emissive_map":{"texture":2,"uv_set":0,"sampler":[0,0,0,0,0]}})).unwrap());
    replacement.textures = vec![
        serde_json::from_value(
            json!({"id":2,"width":1,"height":1,"format":0,"levels":[[0,255,0,255]]}),
        )
        .unwrap(),
    ];
    let green = renderer.render(&replacement, 31, 31).unwrap();
    assert_eq!(
        &green[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[0, 255, 0, 255]
    );
    assert_eq!(profile(&mut renderer)["drawPreparationBindGroups"], 1);
    // Reintroducing the old scene ID allocates a new registry generation.
    replacement.meshes[0]
        .pbr
        .as_mut()
        .unwrap()
        .emissive_map
        .as_mut()
        .unwrap()
        .texture = 1;
    replacement.textures[0].id = 1;
    replacement.textures[0].levels = vec![vec![0, 0, 255, 255]];
    let blue = renderer.render(&replacement, 31, 31).unwrap();
    assert_eq!(
        &blue[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[0, 0, 255, 255]
    );
    assert_eq!(profile(&mut renderer)["drawPreparationBuffers"], 0);
    assert_eq!(profile(&mut renderer)["drawPreparationBindGroups"], 1);
    renderer.close_scene_view(0).unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 0);
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn cache_reclamation_admits_ninth_view_and_changed_slots_without_mutating_rejections() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let budget = 16 * 1024 * 1024_u64;
    renderer
        .resource_command(&packet(13, &budget.to_le_bytes()), 24)
        .unwrap();
    let mut frame = fixture(1);
    for id in 1..=8 {
        view(&mut frame, id);
        renderer.render(&frame, 31, 31).unwrap();
        frame.geometries.clear();
    }
    let cached = profile(&mut renderer);
    let descriptor = [
        (budget - renderer.scene_resource_stats().0)
            .to_le_bytes()
            .as_slice(),
        32_u32.to_le_bytes().as_slice(),
        0_u32.to_le_bytes().as_slice(),
    ]
    .concat();
    let reply = renderer
        .resource_command(&packet(1, &descriptor), 56)
        .unwrap();
    let allocation = reply[24..].to_vec();
    assert_eq!(renderer.scene_resource_stats().0, budget);
    view(&mut frame, 9);
    let pixels = renderer.render(&frame, 31, 31).unwrap();
    let admitted = profile(&mut renderer);
    assert_eq!(
        admitted["drawCacheUniformBytes"],
        cached["drawCacheUniformBytes"]
    );
    assert_eq!(admitted["drawPreparationBuffers"], 1);
    assert_eq!(renderer.scene_resource_stats().0, budget);
    assert_eq!(
        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
        &[255, 0, 0, 255]
    );

    // Even reclaiming every older cache cannot fit ten uniforms beside the
    // external reservation. Rejection must preserve the eight cached views.
    let mut oversized = fixture(10);
    oversized.geometries.clear();
    view(&mut oversized, 9);
    let before = renderer.scene_resource_stats();
    assert!(
        renderer
            .render(&oversized, 31, 31)
            .unwrap_err()
            .contains("budget")
    );
    let rejected = profile(&mut renderer);
    assert_eq!(rejected["drawCacheEntries"], admitted["drawCacheEntries"]);
    assert_eq!(
        rejected["drawCacheUniformBytes"],
        admitted["drawCacheUniformBytes"]
    );
    assert_eq!(renderer.scene_resource_stats(), before);
    assert_eq!(renderer.render(&frame, 31, 31).unwrap(), pixels);
    assert_warm(&mut renderer, 1);

    // Replace the sole visible source slot at a completely full budget, then
    // shrink back. Obsolete slots are credited without touching other views.
    frame.meshes.push(frame.meshes[0].clone());
    frame.meshes[0].color_visible = false;
    view(&mut frame, 9);
    assert_eq!(renderer.render(&frame, 31, 31).unwrap(), pixels);
    assert_eq!(profile(&mut renderer)["drawPreparationBuffers"], 1);
    assert_eq!(renderer.scene_resource_stats().0, budget);
    frame.meshes.truncate(1);
    frame.meshes[0].color_visible = true;
    view(&mut frame, 9);
    assert_eq!(renderer.render(&frame, 31, 31).unwrap(), pixels);
    assert_eq!(profile(&mut renderer)["drawPreparationBuffers"], 1);
    assert_eq!(renderer.scene_resource_stats().0, budget);
    // Growing an existing view also reclaims an older optional cache, even
    // though no view-count eviction is otherwise required.
    frame.meshes.push(frame.meshes[0].clone());
    view(&mut frame, 9);
    assert_eq!(renderer.render(&frame, 31, 31).unwrap(), pixels);
    let grown = profile(&mut renderer);
    assert_eq!(grown["drawPreparationBuffers"], 1);
    assert_eq!(
        grown["drawCacheUniformBytes"],
        cached["drawCacheUniformBytes"]
    );
    assert_eq!(renderer.scene_resource_stats().0, budget);
    renderer
        .resource_command(&packet(6, &allocation), 24)
        .unwrap();
    for id in 1..=9 {
        renderer.close_scene_view(id).unwrap();
    }
    assert_eq!(renderer.scene_resource_stats().0, 0);
    assert_eq!(profile(&mut renderer)["drawCacheEntries"], 0);
}
