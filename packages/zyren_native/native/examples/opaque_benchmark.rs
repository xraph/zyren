use glam::{Mat4, Vec3};
use serde_json::json;
use std::time::Instant;
use zyren_runtime::{
    renderer::Renderer,
    scene::{Frame, Mesh},
};

fn main() {
    let output = std::env::args().nth(1).expect("output directory");
    let motion = std::env::args().nth(2).as_deref() == Some("motion");
    std::fs::create_dir_all(&output).unwrap();
    let mut frame: Frame = serde_json::from_value(json!({
        "version":1, "view_projection":Mat4::IDENTITY.to_cols_array(),
        "background":[0,0,0], "light_direction":[0,0,1], "ambient":0,
        "geometries":[{"id":1,"positions":[[-0.012,-0.012,0.4],[0.012,-0.012,0.4],[0,0.012,0.4]],
        "normals":[[0,0,1],[0,0,1],[0,0,1]], "indices":[0,1,2]}], "meshes":[]
    }))
    .unwrap();
    for i in 0..4096 {
        frame.meshes.push(Mesh {
            geometry: 1,
            unlit: true,
            side: 1,
            color: if i % 2 == 0 {
                [1., 0.25, 0.]
            } else {
                [0., 0.5, 1.]
            },
            model: Mat4::from_translation(Vec3::new(
                (i % 64) as f32 * 0.03 - 0.945,
                (i / 64) as f32 * 0.03 - 0.945,
                0.,
            ))
            .to_cols_array(),
            ..Default::default()
        });
    }
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut samples = Vec::new();
    let mut reference = Vec::new();
    for i in 0..40 {
        if motion {
            frame.view_projection[12] = (i as f32 - 10.) * 0.001;
            frame.view_projection[13] = (i % 7) as f32 * 0.0005;
        }
        let started = Instant::now();
        let pixels = renderer.render(&frame, 1024, 1024).unwrap();
        let elapsed = started.elapsed().as_nanos() as u64;
        let request = serde_json::to_vec(
            &json!({"version":1,"request":1,"command":{"operation":"frameProfile"}}),
        )
        .unwrap();
        let reply: serde_json::Value =
            serde_json::from_slice(&renderer.graph_command(&request, 256 * 1024).unwrap()).unwrap();
        if i == 0 || motion {
            reference = pixels.clone();
        }
        if !motion {
            assert_eq!(pixels, reference);
        }
        if i >= 10 {
            if motion {
                image::save_buffer(
                    format!("{output}/frame-{i:02}.png"),
                    &pixels,
                    1024,
                    1024,
                    image::ColorType::Rgba8,
                )
                .unwrap();
            }
            samples.push(json!({"frameIndex":i,"imageCrc32":crc32fast::hash(&pixels),"wallNs":elapsed,"drawCalls":renderer.scene_draw_stats().0,"profile":reply["result"]}));
        }
        frame.geometries.clear();
    }
    image::save_buffer(
        format!("{output}/opaque.png"),
        &reference,
        1024,
        1024,
        image::ColorType::Rgba8,
    )
    .unwrap();
    std::fs::write(format!("{output}/opaque.rgba"), &reference).unwrap();
    println!(
        "{}",
        json!({"motion":motion,"adapter":renderer.adapter_name,"backend":format!("{:?}",renderer.backend),"meshes":4096,"size":[1024,1024],"warmup":10,"samples":samples})
    );
}
