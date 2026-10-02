use super::*;
use crate::scene_packet::ViewState;
use glam::Mat4;
use serde_json::json;

fn scene() -> Frame {
    let mut frame: Frame = serde_json::from_value(json!({
        "version":1,"view_projection":Mat4::IDENTITY.to_cols_array(),"background":[0,0,0],
        "light_direction":[0,0,1],"ambient":0,
        "color_pipeline":{"tone_mapping":0,"exposure":1},
        "geometries":[{"id":1,"positions":[[-0.8,-0.8,0.4],[0.8,-0.8,0.4],[0,0.8,0.4]],
          "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":Mat4::IDENTITY.to_cols_array(),"color":[1,0,0],"unlit":true}]
    })).unwrap();
    frame.binary = Some(ViewState {
        view: 1,
        revision: 1,
        retained: [1].into(),
        meshes: frame.meshes.clone(),
        retained_textures: Default::default(),
        retained_instances: Default::default(),
        retained_poses: Default::default(),
    });
    frame.temporal = Some(TemporalInput {
        history_weight: 0.9,
        depth_tolerance: 0.01,
        max_bytes: MAX_BYTES,
        reset: 0,
        camera: 1,
        origin: [0., 0., 3.],
        forward: [0., 0., -1.],
        target_distance: 3.,
        projection: Mat4::IDENTITY.to_cols_array(),
        identities: vec![[1, 1]],
    });
    frame
}
fn motion_pixel(renderer: &Renderer) -> [f32; 4] {
    let texture = &renderer.temporal.working.as_ref().unwrap().motion;
    let buffer = renderer.device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("test motion pixel"),
        size: 256,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = renderer.device.create_command_encoder(&Default::default());
    encoder.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo {
            origin: wgpu::Origin3d { x: 15, y: 15, z: 0 },
            ..texture.as_image_copy()
        },
        wgpu::TexelCopyBufferInfo {
            buffer: &buffer,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(256),
                rows_per_image: Some(1),
            },
        },
        wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
    );
    renderer.queue.submit([encoder.finish()]);
    let (tx, rx) = std::sync::mpsc::channel();
    buffer
        .slice(..)
        .map_async(wgpu::MapMode::Read, move |r| tx.send(r).unwrap());
    renderer
        .device
        .poll(wgpu::PollType::wait_indefinitely())
        .unwrap();
    rx.recv().unwrap().unwrap();
    let mapped = buffer.slice(..).get_mapped_range().unwrap();
    let values: [f32; 4] = bytemuck::pod_read_unaligned(&mapped[..16]);
    drop(mapped);
    buffer.unmap();
    values
}
#[test]
#[ignore = "requires native GPU"]
fn motion_tracks_accepted_geometry_and_budget_failure_preserves_history() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = scene();
    renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(motion_pixel(&renderer)[3], 0.);
    renderer.render(&frame, 31, 31).unwrap();
    let still = motion_pixel(&renderer);
    assert!(still[0].abs() < 1e-6 && still[1].abs() < 1e-6);
    assert_eq!(still[3], 1.);
    frame.meshes[0].model[12] = 0.2;
    renderer.render(&frame, 31, 31).unwrap();
    let moved = motion_pixel(&renderer);
    assert!((moved[0] + 0.1).abs() < 1e-6 && moved[1].abs() < 1e-6);
    assert!((moved[2] - 0.4).abs() < 1e-6 && moved[3] == 1.);
    let before = renderer.temporal.views[&1].current.frame;
    let bytes = renderer.temporal_resource_bytes();
    assert_eq!(bytes, 31 * 31 * 52 + 3 * 24 * 2);
    frame.temporal.as_mut().unwrap().max_bytes = bytes - 1;
    assert!(
        renderer
            .render(&frame, 31, 31)
            .unwrap_err()
            .contains("budget")
    );
    assert_eq!(renderer.temporal.views[&1].current.frame, before);
    assert_eq!(renderer.temporal_resource_bytes(), bytes);
    frame.temporal.as_mut().unwrap().max_bytes = MAX_BYTES;
    renderer.render(&frame, 31, 31).unwrap();
    assert_eq!(renderer.temporal.views[&1].current.frame, before + 1);
    renderer.render(&frame, 23, 23).unwrap();
    assert_eq!(renderer.temporal.views[&1].current.frame, 1);
    frame.temporal.as_mut().unwrap().projection[0] = 2.;
    renderer.render(&frame, 23, 23).unwrap();
    assert_eq!(renderer.temporal.views[&1].current.frame, 1);
    renderer.close_scene_view(1).unwrap();
    assert_eq!(renderer.temporal_resource_bytes(), 0);
}
