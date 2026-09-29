use glam::{Mat4, Vec3};
use zyren_runtime::{
    instances::{InstancePatch, InstanceRange, Instances},
    renderer::Renderer,
    scene::Frame,
    scene_packet::ViewState,
};
use serde_json::json;

fn recipe(id: u32, count: usize) -> Instances {
    Instances {
        id,
        transforms: vec![Mat4::IDENTITY.to_cols_array(); count],
        colors: vec![[1.; 3]; count],
    }
}
#[test]
fn instance_admission_and_ranges_are_bounded_and_preserve_snapshots() {
    let base = recipe(1, 3);
    let values = Mat4::from_scale(Vec3::new(-2., 3., 4.)).to_cols_array();
    let mut patch = InstancePatch {
        id: 2,
        base: 1,
        ranges: vec![InstanceRange {
            first: 1,
            transforms: vec![values],
            colors: vec![[0.2, 0.4, 0.6]],
        }],
    };
    let next = patch.apply(&base).unwrap();
    assert_eq!(base.transforms[1], Mat4::IDENTITY.to_cols_array());
    let gpu = next.gpu_values(1..2);
    assert_eq!(gpu.len(), 32);
    assert_eq!(&gpu[28..32], &[0.2, 0.4, 0.6, 1.]);
    assert_eq!(base.colors[1], [1.; 3]);
    assert_eq!(gpu[16], -0.5);
    assert_eq!(gpu[19], -1.);
    assert!((gpu[21] - 1. / 3.).abs() < 1e-6);
    patch.ranges[0].first = 3;
    assert!(patch.apply(&base).is_err());
    for values in [
        Mat4::ZERO.to_cols_array(),
        {
            let mut m = Mat4::IDENTITY.to_cols_array();
            m[3] = 1.;
            m
        },
        [f32::INFINITY; 16],
        Mat4::from_scale(Vec3::splat(1e-20)).to_cols_array(),
    ] {
        assert!(
            Instances {
                id: 1,
                transforms: vec![values],
                colors: vec![[1.; 3]]
            }
            .validate()
            .is_err()
        );
    }
    assert!(recipe(1, 100001).validate().is_err());
    assert!(recipe(0, 1).validate().is_err());
}

#[test]
fn invalid_color_ranges_leave_the_base_version_unchanged() {
    let base = recipe(1, 2);
    let mut patch = InstancePatch {
        id: 2,
        base: 1,
        ranges: vec![InstanceRange {
            first: 0,
            transforms: vec![Mat4::IDENTITY.to_cols_array()],
            colors: vec![[1., 0., 0.]],
        }],
    };
    assert_eq!(patch.apply(&base).unwrap().colors[0], [1., 0., 0.]);
    for colors in [
        vec![],
        vec![[1.; 3]; 2],
        vec![[f32::NAN, 1., 1.]],
        vec![[1.1, 0., 0.]],
    ] {
        patch.ranges[0].colors = colors;
        assert!(patch.apply(&base).is_err());
        assert_eq!(base.colors, [[1.; 3]; 2]);
    }
    let mut bad = base.clone();
    bad.colors.pop();
    assert!(bad.validate().is_err());
}
fn frame(count: usize) -> Frame {
    let mut f:Frame=serde_json::from_value(json!({
        "version":1,"view_projection":Mat4::IDENTITY.to_cols_array(),"background":[0,0,0],"light_direction":[0,0,1],"ambient":0,
        "geometries":[{"id":1,"positions":[[-0.1,-0.1,0.4],[0.1,-0.1,0.4],[0,0.1,0.4]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":Mat4::IDENTITY.to_cols_array(),"color":[1,0,0],"unlit":true,"side":1}]
    })).unwrap();
    f.instances.push(recipe(1, count));
    f.meshes[0].instances = 1;
    f.meshes[0].instance_count = count as u32;
    f.binary = Some(ViewState {
        view: 1,
        revision: 1,
        retained: [1].into(),
        meshes: f.meshes.clone(),
        retained_textures: Default::default(),
        retained_instances: [1].into(),
        retained_poses: Default::default(),
    });
    f
}
#[test]
#[ignore = "requires a native GPU"]
fn ten_thousand_instances_share_one_draw_and_pipeline() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = frame(10000);
    for (i, t) in f.instances[0].transforms.iter_mut().enumerate() {
        *t = Mat4::from_scale_rotation_translation(
            Vec3::new(if i % 2 == 0 { -0.1 } else { 0.1 }, 0.1, 1.),
            glam::Quat::IDENTITY,
            Vec3::new(
                (i % 100) as f32 * 0.019 - 0.94,
                (i / 100) as f32 * 0.019 - 0.94,
                0.,
            ),
        )
        .to_cols_array();
    }
    let pixels = renderer.render(&f, 201, 201).unwrap();
    assert_eq!(renderer.scene_draw_stats(), (1, 1));
    assert!(pixels.chunks_exact(4).filter(|p| p[0] > 200).count() > 10000);
    let (resident, uploaded) = renderer.scene_resource_stats();
    assert_eq!(resident, 10000 * 128 + 3 * 24 + 3 * 4);
    assert_eq!(uploaded, resident);
    f.geometries.clear();
    f.instances.clear();
    f.meshes[0].instance_count = 1;
    renderer.render(&f, 31, 31).unwrap();
    assert_eq!(renderer.scene_draw_stats(), (1, 1));
    assert_eq!(renderer.scene_resource_stats(), (resident, uploaded));
    f.meshes[0].instance_count = 10001;
    assert!(renderer.render(&f, 31, 31).is_err());
    f.meshes[0].instance_count = 1;
    let owned = f.binary.as_mut().unwrap().retained_instances.clone();
    f.binary.as_mut().unwrap().retained_instances.clear();
    assert!(renderer.render(&f, 31, 31).is_err());
    f.binary.as_mut().unwrap().retained_instances = owned;
    renderer.render(&f, 31, 31).unwrap();
    assert_eq!(renderer.scene_resource_stats(), (resident, uploaded));
    renderer.close_scene_view(1).unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 0);
}
#[test]
#[ignore = "requires a native GPU"]
fn reflected_instances_keep_front_face_and_back_normal_semantics() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut f = frame(2);
    f.instances[0].transforms[0] = Mat4::from_translation(Vec3::new(-0.5, 0., 0.)).to_cols_array();
    f.instances[0].transforms[1] = Mat4::from_scale_rotation_translation(
        Vec3::new(-1., 1., 1.),
        glam::Quat::IDENTITY,
        Vec3::new(0.5, 0., 0.),
    )
    .to_cols_array();
    for mirrored in [false, true] {
        f.meshes[0].model =
            Mat4::from_scale(Vec3::new(if mirrored { -1. } else { 1. }, 1., 1.)).to_cols_array();
        for reverse in [false, true] {
            f.view_projection =
                Mat4::from_scale(Vec3::new(if reverse { -1. } else { 1. }, 1., 1.)).to_cols_array();
            for side in 0..=2 {
                f.meshes[0].side = side;
                f.meshes[0].unlit = false;
                f.light_direction = [0., 0., if reverse { -1. } else { 1. }];
                let pixels = renderer.render(&f, 101, 101).unwrap();
                f.geometries.clear();
                f.instances.clear();
                let visible = side == 0 || (side == 1 && !reverse) || (side == 2 && reverse);
                for x in [25, 75] {
                    assert_eq!(
                        pixels[(50 * 101 + x) * 4],
                        if visible { 255 } else { 0 },
                        "side {side} reverse {reverse} parent reflection {mirrored} x{x}"
                    );
                }
            }
        }
    }
}
