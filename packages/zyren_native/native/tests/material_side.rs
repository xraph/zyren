use serde_json::json;
use zyren_runtime::{
    renderer::Renderer,
    scene::{Frame, Mesh},
};

#[test]
fn material_side_checks_wire_values_and_expanded_primitives() {
    for side in 0..=2 {
        let mesh = Mesh {
            side,
            ..Default::default()
        };
        assert!(mesh.validate_material().is_ok());
    }
    assert!(
        Mesh {
            side: 3,
            ..Default::default()
        }
        .validate_material()
        .is_err()
    );
    assert!(
        Mesh {
            side: 1,
            primitive_kind: 1,
            unlit: true,
            ..Default::default()
        }
        .validate_material()
        .is_err()
    );
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn culling_and_back_normals_follow_mirrored_world_transforms() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame: Frame = serde_json::from_value(json!({
        "version":1,"view_projection":glam::Mat4::IDENTITY.to_cols_array(),
        "background":[0,0,0],"light_direction":[0,0,1],"ambient":0,
        "geometries":[{"id":1,"positions":[[-1,-1,0.4],[1,-1,0.4],[0,1,0.4]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),
            "color":[1,0,0],"unlit":true}]
    }))
    .unwrap();
    for mirrored in [false, true] {
        frame.meshes[0].model =
            glam::Mat4::from_scale(glam::Vec3::new(if mirrored { -1. } else { 1. }, 1., 1.))
                .to_cols_array();
        for reverse in [false, true] {
            frame.view_projection =
                glam::Mat4::from_scale(glam::Vec3::new(if reverse { -1. } else { 1. }, 1., 1.))
                    .to_cols_array();
            for side in 0..=2 {
                frame.meshes[0].side = side;
                frame.meshes[0].unlit = true;
                let visible = side == 0 || (side == 1 && !reverse) || (side == 2 && reverse);
                let pixels = renderer.render(&frame, 31, 31).unwrap();
                frame.geometries.clear();
                assert_eq!(
                    &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
                    if visible {
                        &[255, 0, 0, 255]
                    } else {
                        &[0, 0, 0, 255]
                    },
                    "side {side}, mirrored {mirrored}, reverse {reverse}"
                );
                if visible {
                    frame.meshes[0].unlit = false;
                    frame.light_direction = [0., 0., if reverse { -1. } else { 1. }];
                    let pixels = renderer.render(&frame, 31, 31).unwrap();
                    assert_eq!(
                        &pixels[(15 * 31 + 15) * 4..(15 * 31 + 15) * 4 + 4],
                        &[255, 0, 0, 255]
                    );
                }
            }
        }
    }
}
