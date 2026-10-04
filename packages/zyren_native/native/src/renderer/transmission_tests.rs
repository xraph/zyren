use super::*;
use serde_json::json;

fn fixture() -> Frame {
    let identity = glam::Mat4::IDENTITY.to_cols_array();
    serde_json::from_value(json!({
        "version":1,"view_projection":identity,"background":[0.13,0.27,0.41],
        "background_alpha":0.6,"light_direction":[0,0,1],"ambient":0,
        "geometries":[{"id":1,"positions":[[-0.9,-0.8,0.7],[0.9,-0.8,0.7],[0,0.9,0.7]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[
            {"geometry":1,"model":identity,"color":[0.9,0.2,0.1],"unlit":true},
            {"geometry":1,"model":glam::Mat4::from_translation(glam::Vec3::new(0.2,0.,-0.1)).to_cols_array(),"color":[0.1,0.7,0.2],"unlit":true},
            {"geometry":1,"model":glam::Mat4::from_translation(glam::Vec3::new(-0.2,0.,-0.2)).to_cols_array(),"color":[0.2,0.1,0.8],"unlit":true},
            {"geometry":1,"model":glam::Mat4::from_translation(glam::Vec3::new(0.,0.,-0.4)).to_cols_array(),"color":[1,1,1],"unlit":false,"pbr":{"metallic":0,"roughness":0,"emissive":[0,0,0],"physical":[1.5,1,0,0,1,1,1,1,0,0,0,0,0,1,1,0],"transmission":[1,0.2,0,0,1,1,1,0]}}
        ]
    })).unwrap()
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn opaque_reuse_matches_redraw_and_counts_seed_work() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut reference = pollster::block_on(Renderer::new()).unwrap();
    reference.transmission.disable_reuse = true;
    let mut frame = fixture();
    for case in 0..12 {
        frame.settings.enabled = case % 2 == 1;
        frame.settings.depth_strategy = if case >= 6 { 1 } else { 0 };
        for mesh in &mut frame.meshes {
            mesh.reversed_depth = frame.settings.reversed_depth();
        }
        frame.meshes[3].pbr.as_mut().unwrap().roughness = if case % 3 == 0 { 0. } else { 0.7 };
        frame.meshes[3].pbr.as_mut().unwrap().optical[4] = if case % 3 == 2 { 1. } else { 0. };
        let size = 31 + case;
        let actual = renderer.render(&frame, size, size).unwrap();
        let expected = reference.render(&frame, size, size).unwrap();
        frame.geometries.clear();
        assert_eq!(actual, expected, "case {case}");
        let p = renderer.profile.borrow();
        let r = reference.profile.borrow();
        assert_eq!(p.executed_mesh_draws, Some(4));
        assert_eq!(r.executed_mesh_draws, Some(7));
        assert_eq!(p.passes["scene"].draw_calls, Some(2));
        assert_eq!(r.passes["scene"].draw_calls, Some(4));
        println!(
            "case {case}: equal pixels crc={:08x}; mesh 7 -> 4; main pass 4 -> 2 (includes seed)",
            crc32fast::hash(&actual)
        );
        if let Ok(dir) = std::env::var("TASK8A_EVIDENCE") {
            image::save_buffer(
                format!("{dir}/reuse-{case}.png"),
                &actual,
                size,
                size,
                image::ColorType::Rgba8,
            )
            .unwrap();
            image::save_buffer(
                format!("{dir}/reference-{case}.png"),
                &expected,
                size,
                size,
                image::ColorType::Rgba8,
            )
            .unwrap();
        }
    }
    // Alpha mask, clipping and transparent composition retain the same result.
    frame.settings.depth_strategy = 0;
    for mesh in &mut frame.meshes {
        mesh.reversed_depth = false;
    }
    frame.meshes[0].alpha_mode = 1;
    frame.meshes[0].opacity = 0.4;
    frame.meshes[0].alpha_cutoff = 0.5;
    frame.meshes[1].clipping_planes = vec![[1., 0., 0., 0.]];
    let mut transparent = frame.meshes[2].clone();
    transparent.alpha_mode = 2;
    transparent.opacity = 0.3;
    transparent.model = glam::Mat4::from_translation(glam::Vec3::new(0., 0., -0.6)).to_cols_array();
    frame.meshes.push(transparent);
    let actual = renderer.render(&frame, 47, 47).unwrap();
    assert_eq!(actual, reference.render(&frame, 47, 47).unwrap());
    assert_eq!(renderer.profile.borrow().executed_mesh_draws, Some(5));
    assert_eq!(
        renderer.profile.borrow().passes["scene"].draw_calls,
        Some(3)
    );
    println!(
        "masked/clipped/transparent: equal pixels crc={:08x}; mesh 8 -> 5; main 5 -> 3 (includes seed)",
        crc32fast::hash(&actual)
    );
    if let Ok(dir) = std::env::var("TASK8A_EVIDENCE") {
        image::save_buffer(
            format!("{dir}/masked-clipped-transparent.png"),
            &actual,
            47,
            47,
            image::ColorType::Rgba8,
        )
        .unwrap();
    }
    frame.meshes.pop();
    // Explicit render order places a consumer before an opaque draw.
    frame.meshes[3].render_order = -1;
    assert_eq!(
        renderer.render(&frame, 39, 39).unwrap(),
        reference.render(&frame, 39, 39).unwrap()
    );
    assert_eq!(renderer.profile.borrow().executed_mesh_draws, Some(7));
    frame.meshes[3].render_order = 0;
    frame.settings.sample_count = 4;
    frame.settings.enabled = true;
    assert_eq!(
        renderer.render(&frame, 39, 39).unwrap(),
        reference.render(&frame, 39, 39).unwrap()
    );
    assert_eq!(renderer.profile.borrow().executed_mesh_draws, Some(7));
    // The same guarded path rejects mismatched formats and loaded depth.
    assert!(!renderer.reuse_opaque_capture(&frame, wgpu::TextureFormat::Rgba8Unorm, false));
    assert!(!renderer.reuse_opaque_capture(&frame, wgpu::TextureFormat::Rgba16Float, true));
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn collapsed_filter_matches_nine_taps_with_measured_gpu_loads() {
    use wgpu::util::DeviceExt;
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    renderer.render(&fixture(), 31, 31).unwrap();
    let targets = renderer.transmission.targets.as_ref().unwrap();
    let source = include_str!("transmission.wgsl")
        .split("fn physical_transmission")
        .next()
        .unwrap()
        .replace("let size=", "atomicAdd(&result.taps,1u); let size=")
        .replace(
            "let depth = textureLoad",
            "atomicAdd(&result.depths,1u); let depth = textureLoad",
        )
        .replace(
            "color+=textureLoad",
            "atomicAdd(&result.colors,1u); color+=textureLoad",
        );
    for (case, roughness, ior, thickness, rejected, offscreen) in [
        ("smooth", 0., 1.5, 0., false, false),
        ("rough", 0.7, 1.5, 0., false, false),
        ("ior_one", 0.7, 1., 0., false, false),
        ("foreground", 0., 1.5, 0., true, false),
        ("offscreen", 0., 1.5, 10., false, true),
    ] {
        let mut results = Vec::new();
        for reference in [false, true] {
            let body = if reference {
                source.replace(
                    "let extent=select(1,0,all(radius==vec2(0.)));",
                    "let extent=1;",
                )
            } else {
                source.clone()
            };
            let code = format!(
                r#"
struct U {{ capture_projection: mat4x4<f32>, viewport: vec4<f32>, clipping: vec4<f32> }}
struct E {{ params: vec4<f32> }}
struct StandardSurface {{ roughness: f32, transmission: array<vec4<f32>,2> }}
struct VertexOutput {{ position: vec4<f32>, world_scale: vec3<f32>, relative_position: vec3<f32> }}
struct Result {{ value: vec4<f32>, taps: atomic<u32>, depths: atomic<u32>, colors: atomic<u32>, pad: u32 }}
@group(0) @binding(0) var<storage,read_write> result: Result;
var<private> uniforms: U;
var<private> environment: E;
fn normalized_or(v:vec3<f32>,fallback:vec3<f32>)->vec3<f32>{{return normalize(v);}}
fn environment_specular(v:vec3<f32>,r:f32)->vec3<f32>{{return vec3(0.);}}
{body}
@compute @workgroup_size(1) fn main() {{
    uniforms=U(mat4x4<f32>(vec4(1.,0.,0.,0.),vec4(0.,1.,0.,0.),vec4(0.,0.,1.,0.),vec4(0.,0.,0.,1.)),vec4(31.,31.,0.,0.),vec4(0.));
    environment=E(vec4(0.));
    let surface=StandardSurface({roughness},array<vec4<f32>,2>(vec4(1.,{thickness},0.,0.),vec4(1.)));
    let input=VertexOutput(vec4(15.5,15.5,{depth},1.),vec3(1.),vec3({x},0.,0.));
    result.value=transmission_path(input,vec3(0.,0.,1.),vec3(0.,0.,1.),surface,{ior});
}}
"#,
                depth = if rejected { 0.99 } else { 0.1 },
                x = if offscreen { 100. } else { 0. }
            );
            let shader = renderer
                .device
                .create_shader_module(wgpu::ShaderModuleDescriptor {
                    label: Some("instrumented production transmission"),
                    source: wgpu::ShaderSource::Wgsl(code.into()),
                });
            let pipeline =
                renderer
                    .device
                    .create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                        label: None,
                        layout: None,
                        module: &shader,
                        entry_point: Some("main"),
                        compilation_options: Default::default(),
                        cache: None,
                    });
            let output = renderer
                .device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: None,
                    contents: &[0; 32],
                    usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
                });
            let readback = renderer.device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size: 32,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });
            let binding = renderer
                .device
                .create_bind_group(&wgpu::BindGroupDescriptor {
                    label: None,
                    layout: &pipeline.get_bind_group_layout(0),
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: output.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 13,
                            resource: wgpu::BindingResource::TextureView(&targets.color),
                        },
                        wgpu::BindGroupEntry {
                            binding: 14,
                            resource: wgpu::BindingResource::TextureView(&targets.depth),
                        },
                    ],
                });
            let mut encoder = renderer.device.create_command_encoder(&Default::default());
            {
                let mut pass = encoder.begin_compute_pass(&Default::default());
                pass.set_pipeline(&pipeline);
                pass.set_bind_group(0, &binding, &[]);
                pass.dispatch_workgroups(1, 1, 1);
            }
            encoder.copy_buffer_to_buffer(&output, 0, &readback, 0, 32);
            renderer.queue.submit([encoder.finish()]);
            let (tx, rx) = std::sync::mpsc::channel();
            readback
                .slice(..)
                .map_async(wgpu::MapMode::Read, move |r| tx.send(r).unwrap());
            renderer
                .device
                .poll(wgpu::PollType::Wait {
                    submission_index: None,
                    timeout: None,
                })
                .unwrap();
            rx.recv().unwrap().unwrap();
            let bytes = readback.slice(..).get_mapped_range().unwrap().to_vec();
            results.push(
                bytes
                    .chunks_exact(4)
                    .map(|b| u32::from_le_bytes(b.try_into().unwrap()))
                    .collect::<Vec<_>>(),
            );
        }
        for channel in 0..4 {
            assert!(
                (f32::from_bits(results[0][channel]) - f32::from_bits(results[1][channel])).abs()
                    < 1e-6,
                "{case}: {results:?}"
            );
        }
        if case == "rough" {
            assert_eq!(results[0][4..7], results[1][4..7]);
        } else {
            assert_eq!(results[0][4] + 8, results[1][4], "{case}");
        }
        println!(
            "{case}: GPU [tap, depth load, color load] optimized={:?}, reference={:?}",
            &results[0][4..7],
            &results[1][4..7]
        );
    }
}
