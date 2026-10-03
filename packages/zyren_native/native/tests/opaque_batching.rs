use glam::{Mat4, Vec3};
use serde_json::json;
use zyren_runtime::{
    renderer::Renderer,
    scene::{Frame, Mesh},
};
fn fixture() -> Frame {
    let mut frame: Frame = serde_json::from_value(json!({"version":1,"view_projection":Mat4::IDENTITY.to_cols_array(),"background":[0,0,0],"light_direction":[0,0,1],"ambient":0.2,"geometries":[{"id":1,"positions":[[-0.18,-0.18,0.4],[0.18,-0.18,0.4],[0,0.18,0.4]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],"meshes":[]})).unwrap();
    for i in 0..4 {
        frame.meshes.push(Mesh {
            geometry: 1,
            unlit: true,
            side: 1,
            color: if i % 2 == 0 {
                [1., 0., 0.]
            } else {
                [0., 1., 0.]
            },
            model: Mat4::from_translation(Vec3::new(i as f32 * 0.45 - 0.675, 0., 0.))
                .to_cols_array(),
            ..Default::default()
        });
    }
    frame
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
fn baseline(renderer: &mut Renderer, frame: &mut Frame) -> Vec<u8> {
    let mut f = frame.clone();
    for (i, m) in f.meshes.iter_mut().enumerate() {
        m.render_order = i as i32;
    }
    let pixels = renderer.render(&f, 201, 101).unwrap();
    frame.geometries.clear();
    pixels
}
#[test]
#[ignore = "requires a native GPU"]
fn compatible_meshes_preserve_pixels_and_reuse_only_unchanged_transforms() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture();
    let expected = baseline(&mut renderer, &mut frame);
    let pixels = renderer.render(&frame, 201, 101).unwrap();
    assert_eq!(pixels, expected);
    let p = profile(&mut renderer);
    assert_eq!(p["executedMeshDraws"], 2);
    assert_eq!(p["opaqueBatchDraws"], 2);
    assert_eq!(p["batchedSourceDraws"], 4);
    assert_eq!(p["automaticInstanceUploadBytes"], 512);
    assert_eq!(p["passes"]["scene"]["drawCalls"], 2);
    assert_eq!(p["pipelineSwitches"], 1);
    assert_eq!(p["bindGroupSwitches"], 2);
    frame.geometries.clear();
    renderer.render(&frame, 201, 101).unwrap();
    assert_eq!(profile(&mut renderer)["automaticInstanceUploadBytes"], 0);
    frame.view_projection[12] = 0.01;
    renderer.render(&frame, 201, 101).unwrap();
    assert_eq!(profile(&mut renderer)["drawPlanReuses"], 0);
    assert_eq!(profile(&mut renderer)["automaticInstanceUploadBytes"], 0);
    frame.meshes[0].model[13] = 0.02;
    renderer.render(&frame, 201, 101).unwrap();
    assert_eq!(profile(&mut renderer)["drawPlanReuses"], 0);
    assert_eq!(profile(&mut renderer)["automaticInstanceUploadBytes"], 512);
    frame.meshes[0].color = [0., 0., 1.];
    renderer.render(&frame, 201, 101).unwrap();
    assert_eq!(profile(&mut renderer)["drawPlanReuses"], 0);
    assert_eq!(profile(&mut renderer)["executedMeshDraws"], 3);
    renderer.close_scene_view(0).unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 0);
}
#[test]
#[ignore = "requires a native GPU"]
fn opaque_painter_barriers_and_coplanar_ties_keep_submission_order() {
    for mode in 0..4 {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let mut f = fixture();
        for (i, m) in f.meshes.iter_mut().enumerate() {
            m.model = Mat4::IDENTITY.to_cols_array();
            m.model[14] = if mode == 2 { 0. } else { i as f32 * 0.02 };
            if mode == 0 {
                m.depth_test = false;
            }
            if mode == 1 {
                m.depth_write = Some(false);
            }
            if mode == 3 {
                m.render_order = -(i as i32);
            }
        }
        let pixels = renderer.render(&f, 201, 101).unwrap();
        assert_eq!(profile(&mut renderer)["opaqueBatchDraws"], 0);
        let center = &pixels[(50 * 201 + 100) * 4..(50 * 201 + 100) * 4 + 3];
        assert_eq!(
            center,
            if mode <= 1 {
                &[0, 255, 0]
            } else {
                &[255, 0, 0]
            },
            "mode {mode}"
        );
    }
}
#[test]
#[ignore = "requires a native GPU"]
fn reflected_batches_match_original_side_and_normal_semantics() {
    for side in 0..3 {
        for reversed in [false, true] {
            let mut renderer = pollster::block_on(Renderer::new()).unwrap();
            let mut f = fixture();
            for m in &mut f.meshes {
                m.color = [1., 0., 0.];
                m.unlit = false;
                m.side = side;
                m.model[0] = -1.;
            }
            if reversed {
                f.view_projection[0] = -1.;
                f.light_direction = [0., 0., -1.];
            }
            let expected = baseline(&mut renderer, &mut f);
            let pixels = renderer.render(&f, 201, 101).unwrap();
            assert_eq!(pixels, expected, "side {side} reverse {reversed}");
            assert_eq!(profile(&mut renderer)["opaqueBatchDraws"], 1);
        }
    }
}
#[test]
#[ignore = "requires a native GPU"]
fn mask_and_outline_paths_keep_source_draws_and_count_each_pass() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = fixture();
    for m in &mut f.meshes {
        m.alpha_mode = 1;
    }
    let expected = baseline(&mut renderer, &mut f);
    assert_eq!(renderer.render(&f, 201, 101).unwrap(), expected);
    assert_eq!(profile(&mut renderer)["opaqueBatchDraws"], 2);
    f.settings.outline = Some(zyren_runtime::scene::OutlineSettings {
        color: [0., 0., 1., 1.],
        width: 1,
    });
    for m in &mut f.meshes {
        m.outlined = true;
    }
    let expected = baseline(&mut renderer, &mut f);
    assert_eq!(renderer.render(&f, 201, 101).unwrap(), expected);
    let p = profile(&mut renderer);
    assert_eq!(p["opaqueBatchDraws"], 0);
    assert_eq!(p["executedMeshDraws"], 8);
    assert_eq!(p["passes"]["scene"]["drawCalls"], 4);
    assert_eq!(p["passes"]["outlineMask"]["drawCalls"], 4);
}

#[test]
#[ignore = "requires a native GPU"]
fn interframe_public_allocation_reclaims_completed_batch_then_falls_back() {
    use zyren_runtime::resources::ResourceError;
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
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = fixture();
    let expected = renderer.render(&f, 201, 101).unwrap();
    f.geometries.clear();
    let resident = renderer.scene_resource_stats().0;
    let limit = 16 * 1024 * 1024_u64;
    renderer
        .resource_command(&packet(13, &limit.to_le_bytes()), 24)
        .unwrap();
    let descriptor = |size: u64| {
        [
            size.to_le_bytes().as_slice(),
            48_u32.to_le_bytes().as_slice(),
            0_u32.to_le_bytes().as_slice(),
        ]
        .concat()
    };
    assert_eq!(
        renderer.resource_command(&packet(1, &descriptor(limit)), 56),
        Err(ResourceError::BudgetExceeded)
    );
    renderer.render(&f, 201, 101).unwrap();
    assert_eq!(profile(&mut renderer)["automaticInstanceUploadBytes"], 0);
    let allocation = renderer
        .resource_command(&packet(1, &descriptor(limit - resident + 512)), 56)
        .unwrap();
    assert_eq!(renderer.render(&f, 201, 101).unwrap(), expected);
    assert_eq!(profile(&mut renderer)["opaqueBatchDraws"], 0);
    assert_eq!(profile(&mut renderer)["executedMeshDraws"], 4);
    renderer
        .resource_command(&packet(6, &allocation[24..]), 24)
        .unwrap();
    assert_eq!(renderer.render(&f, 201, 101).unwrap(), expected);
    assert_eq!(profile(&mut renderer)["opaqueBatchDraws"], 2);
}

#[test]
#[ignore = "requires a native GPU"]
fn transmission_counts_batched_capture_and_keeps_glass_separate() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = fixture();
    let mut glass = f.meshes[0].clone();
    glass.unlit = false;
    glass.pbr=Some(serde_json::from_value(json!({"metallic":0,"roughness":0.1,"emissive":[0,0,0],"physical":[1.5,1,0,0,1,1,1,1,0,0,0,0,0,1,1,0],"transmission":[1,0,0,0,1,1,1,0]})).unwrap());
    glass.model[14] = -0.1;
    f.meshes.push(glass);
    let expected = baseline(&mut renderer, &mut f);
    assert_eq!(renderer.render(&f, 201, 101).unwrap(), expected);
    let p = profile(&mut renderer);
    assert_eq!(p["executedMeshDraws"], 5);
    assert_eq!(p["opaqueBatchDraws"], 4);
    assert_eq!(p["passes"]["transmission"]["drawCalls"], 2);
    assert_eq!(p["passes"]["scene"]["drawCalls"], 3);
}

#[test]
#[ignore = "requires a native GPU"]
fn partial_coverage_falls_back_without_changing_pixels() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = fixture();
    for m in &mut f.meshes {
        m.coverage = [0., 0.5];
    }
    let expected = baseline(&mut renderer, &mut f);
    assert_eq!(renderer.render(&f, 201, 101).unwrap(), expected);
    assert_eq!(profile(&mut renderer)["executedMeshDraws"], 4);
    assert_eq!(profile(&mut renderer)["opaqueBatchDraws"], 0);
}

#[test]
#[ignore = "requires a native GPU"]
fn source_plan_limit_rejects_overflow_and_preserves_the_warm_plan() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = fixture();
    f.meshes = (0..4096)
        .map(|i| Mesh {
            geometry: 1,
            unlit: true,
            model: Mat4::from_translation(Vec3::new(i as f32 * 0.5, 0., 0.)).to_cols_array(),
            ..Default::default()
        })
        .collect();
    let expected = renderer.render(&f, 16, 16).unwrap();
    f.geometries.clear();
    assert_eq!(renderer.render(&f, 16, 16).unwrap(), expected);
    let p = profile(&mut renderer);
    assert_eq!(p["drawPlanReuses"], 1);
    assert_eq!(p["automaticInstanceUploadBytes"], 0);
    assert_eq!(p["executedMeshDraws"], 64);
    assert_eq!(p["opaqueBatchDraws"], 64);
    f.meshes.push(f.meshes.last().unwrap().clone());
    assert!(
        renderer
            .render(&f, 16, 16)
            .unwrap_err()
            .contains("mesh limit")
    );
    f.meshes.pop();
    assert_eq!(renderer.render(&f, 16, 16).unwrap(), expected);
    assert_eq!(profile(&mut renderer)["drawPlanReuses"], 1);
}
