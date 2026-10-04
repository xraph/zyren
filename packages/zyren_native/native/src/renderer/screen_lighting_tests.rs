use super::*;
use serde_json::json;
fn fixture() -> Frame {
    let identity = glam::Mat4::IDENTITY.to_cols_array();
    serde_json::from_value(json!({
        "version":1,"view_projection":glam::camera::rh::proj::directx::perspective(1.1,1.,0.1,30.).to_cols_array(),
        "background":[0,0,0],"light_direction":[0,0,1],"ambient":0,
        "geometries":[
            {"id":1,"positions":[[-4,-1,-1],[4,-1,-1],[4,-1,-7],[-4,-1,-7]],"normals":[[0,1,0],[0,1,0],[0,1,0],[0,1,0]],"tangents":[[1,0,0,1],[1,0,0,1],[1,0,0,1],[1,0,0,1]],"indices":[0,1,2,0,2,3]},
            {"id":2,"positions":[[-1,-1,-4],[1,-1,-4],[1,1,-4],[-1,1,-4]],"normals":[[0,0,1],[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2,0,2,3]}
        ],
        "meshes":[
            {"geometry":1,"model":identity,"color":[1,1,1],"unlit":false,"pbr":{"metallic":1,"roughness":0.02,"emissive":[0,0,0]}},
            {"geometry":2,"model":identity,"color":[0,0,0],"unlit":false,"pbr":{"metallic":0,"roughness":1,"emissive":[1,0,0]}}
        ]
    })).unwrap()
}
fn sum(image: &[u8], channel: usize) -> u64 {
    image.chunks_exact(4).map(|p| u64::from(p[channel])).sum()
}
fn save(label: &str, image: &[u8], size: u32) {
    if let Ok(dir) = std::env::var("TASK8C_EVIDENCE") {
        image::save_buffer(
            format!("{dir}/{label}.png"),
            image,
            size,
            size,
            image::ColorType::Rgba8,
        )
        .unwrap();
    }
}
#[test]
fn parameter_and_overlap_limits() {
    assert_eq!(allocation([1024, 1024], 0).unwrap(), 12 * 1024 * 1024);
    assert!(allocation([2500, 2500], 75_000_000).is_err());
    assert!(allocation([u32::MAX, u32::MAX], 0).is_err());
    assert!(
        Settings {
            quality: 3,
            ..Default::default()
        }
        .validate()
        .is_err()
    );
    assert!(
        Settings {
            radius: f32::NAN,
            ..Default::default()
        }
        .validate()
        .is_err()
    );
    assert!(!Settings::default().enabled());
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn current_inputs_reflect_without_environment_and_preserve_emission() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture();
    let baseline = renderer.render(&frame, 96, 96).unwrap();
    frame.geometries.clear();
    frame.settings.screen_lighting = Some(Settings {
        reflections: true,
        quality: 2,
        max_distance: 8.,
        ..Default::default()
    });
    let reflected = renderer.render(&frame, 96, 96).unwrap();
    save("baseline", &baseline, 96);
    save("reflected", &reflected, 96);
    println!(
        "screen red sum {} -> {}",
        sum(&baseline, 0),
        sum(&reflected, 0)
    );
    assert!(sum(&reflected, 0) > sum(&baseline, 0) + 10000);
    assert_eq!(sum(&reflected, 1), 0);
    for (a, b) in baseline.chunks_exact(4).zip(reflected.chunks_exact(4)) {
        if a[0] > 250 {
            assert_eq!(a, b, "emission changed");
        }
    }
    assert_eq!(
        renderer.profile.borrow().passes["screenLightingSource"].draw_calls,
        Some(2)
    );
    assert_eq!(renderer.profile.borrow().executed_mesh_draws, Some(4));
    // Failed preparation cannot supply pixels for the next executed frame.
    let valid = frame.clone();
    frame.settings.screen_lighting.as_mut().unwrap().quality = 9;
    assert!(renderer.render(&frame, 96, 96).is_err());
    frame = valid;
    frame.meshes[1].pbr.as_mut().unwrap().emissive = [0., 1., 0.];
    frame.settings.history_epoch = 10;
    let current = renderer.render(&frame, 97, 97).unwrap();
    assert_eq!(sum(&current, 0), 0);
    assert!(sum(&current, 1) > 10000);
    frame
        .settings
        .screen_lighting
        .as_mut()
        .unwrap()
        .max_roughness = 0.01;
    let rejected = renderer.render(&frame, 97, 97).unwrap();
    assert!(sum(&current, 1) > sum(&rejected, 1) + 10000);
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn ao_changes_indirect_only_and_optional_lobes_keep_reflection_fallback() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture();
    frame.meshes[0].pbr.as_mut().unwrap().metallic = 0.;
    frame.hemispheres = vec![
        serde_json::from_value(
            json!({"sky_color":[1,1,1],"ground_color":[1,1,1],"direction":[0,1,0],"intensity":2}),
        )
        .unwrap(),
    ];
    let baseline = renderer.render(&frame, 96, 96).unwrap();
    frame.geometries.clear();
    frame.settings.screen_lighting = Some(Settings {
        ao: true,
        radius: 2.,
        quality: 2,
        ..Default::default()
    });
    let ao = renderer.render(&frame, 96, 96).unwrap();
    save("ao-off", &baseline, 96);
    save("ao-on", &ao, 96);
    println!(
        "indirect green sum {} -> {}",
        sum(&baseline, 1),
        sum(&ao, 1)
    );
    assert!(sum(&ao, 1) + 1000 < sum(&baseline, 1));
    frame.hemispheres.clear();
    frame.lights=vec![serde_json::from_value(json!({"kind":0,"color":[1,1,1],"intensity":1,"position":[0,0,0],"direction":[0,-1,0],"range":0,"inner_cos":1,"outer_cos":0})).unwrap()];
    let direct_ao = renderer.render(&frame, 96, 96).unwrap();
    frame.settings.screen_lighting = None;
    assert_eq!(
        direct_ao,
        renderer.render(&frame, 96, 96).unwrap(),
        "AO changed direct light or emission"
    );
    frame.lights.clear();
    for lobe in 0..5 {
        let mut p = [
            1.5, 1., 0., 0.2, 1., 1., 1., 0.4, 0., 0., 0., 0., 0., 1., 1., 0.,
        ];
        frame.meshes[0].alpha_mode = 0;
        let material = frame.meshes[0].pbr.as_mut().unwrap();
        material.optical = [0.; 8];
        if lobe == 0 {
            p[2] = 0.5;
        } // coat
        if lobe == 1 {
            p[8] = 0.5;
        } // sheen
        if lobe == 2 {
            p[11] = 0.5;
        } // anisotropy
        if lobe == 3 {
            material.optical = [1., 1.3, 100., 400., 0., 0., 0., 0.];
        }
        if lobe == 4 {
            frame.meshes[0].alpha_mode = 2;
        }
        frame.meshes[0].pbr.as_mut().unwrap().physical = Some(p);
        frame.settings.screen_lighting = None;
        let off = renderer.render(&frame, 63, 63).unwrap();
        frame.settings.screen_lighting = Some(Settings {
            reflections: true,
            quality: 2,
            ..Default::default()
        });
        assert_eq!(
            off,
            renderer.render(&frame, 63, 63).unwrap(),
            "excluded lobe {lobe}"
        );
    }
}

fn view(frame: &mut Frame, id: u64) {
    frame.binary = Some(crate::scene_packet::ViewState {
        view: id,
        revision: 1,
        retained: [1, 2].into_iter().collect(),
        meshes: frame.meshes.clone(),
        retained_instances: Default::default(),
        retained_poses: Default::default(),
        retained_textures: Default::default(),
    });
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn resize_views_msaa_depth_and_retirement_keep_current_inputs() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture();
    frame.settings.screen_lighting = Some(Settings {
        reflections: true,
        quality: 2,
        max_distance: 8.,
        ..Default::default()
    });
    for id in 1..=4 {
        view(&mut frame, id);
        frame.meshes[1].pbr.as_mut().unwrap().emissive = if id % 2 == 0 {
            [0., 1., 0.]
        } else {
            [1., 0., 0.]
        };
        let old = renderer
            .screen_lighting
            .targets
            .as_ref()
            .map(|t| t.color.texture().clone());
        let size = 64 + id as u32;
        let pixels = renderer.render(&frame, size, size).unwrap();
        frame.geometries.clear();
        assert!(sum(&pixels, if id % 2 == 0 { 1 } else { 0 }) > 10000);
        assert_eq!(sum(&pixels, if id % 2 == 0 { 0 } else { 1 }), 0);
        assert_eq!(
            renderer.screen_lighting.bytes(),
            u64::from(size * size) * 12
        );
        if let Some(old) = old {
            assert!(!renderer.draw_cache.borrow().references_texture(&old));
        }
    }
    let current = renderer
        .screen_lighting
        .targets
        .as_ref()
        .unwrap()
        .color
        .texture()
        .clone();
    view(&mut frame, 1);
    frame.settings.screen_lighting = None;
    renderer.render(&frame, 32, 32).unwrap();
    assert_eq!(renderer.screen_lighting.targets.as_ref().unwrap().owner, 4);
    renderer.close_scene_view(1).unwrap();
    assert_eq!(
        renderer
            .screen_lighting
            .targets
            .as_ref()
            .unwrap()
            .color
            .texture(),
        &current
    );
    view(&mut frame, 4);
    frame.settings.screen_lighting = Some(Settings {
        reflections: true,
        quality: 2,
        max_distance: 8.,
        ..Default::default()
    });
    // Distinct shader keys exercise both reverse depth and four-sample main rendering.
    let projection = glam::Mat4::from_cols_array(&frame.view_projection);
    let reverse = glam::Mat4::from_cols(
        glam::Vec4::X,
        glam::Vec4::Y,
        glam::Vec4::new(0., 0., -1., 0.),
        glam::Vec4::new(0., 0., 1., 1.),
    );
    frame.view_projection = (reverse * projection).to_cols_array();
    frame.settings.depth_strategy = 1;
    for mesh in &mut frame.meshes {
        mesh.reversed_depth = true;
    }
    let reversed = renderer.render(&frame, 68, 68).unwrap();
    assert!(sum(&reversed, 1) > 10000);
    frame.settings.enabled = true;
    frame.settings.sample_count = 4;
    let msaa = renderer.render(&frame, 68, 68).unwrap();
    assert!(sum(&msaa, 1) > 10000);
    assert_eq!(sum(&msaa, 0), 0);
    assert_eq!(renderer.screen_lighting.bytes(), 68 * 68 * 12);
    renderer.close_scene_view(4).unwrap();
    assert_eq!(renderer.screen_lighting.bytes(), 0);
    assert!(!renderer.draw_cache.borrow().references_texture(&current));
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn lit_opaque_capture_preserves_transmission_seed_and_gloss_threshold() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut reference = pollster::block_on(Renderer::new()).unwrap();
    reference.transmission.disable_reuse = true;
    let mut frame = fixture();
    frame.settings.screen_lighting = Some(Settings {
        ao: true,
        reflections: true,
        quality: 2,
        max_distance: 8.,
        ..Default::default()
    });
    let mut glass = frame.meshes[1].clone();
    glass.model = glam::Mat4::from_translation(glam::Vec3::new(0., 0., 1.)).to_cols_array();
    glass.color = [1.; 3];
    let material = glass.pbr.as_mut().unwrap();
    material.emissive = [0.; 3];
    material.roughness = 0.;
    material.physical = Some([
        1.5, 1., 0., 0., 1., 1., 1., 1., 0., 0., 0., 0., 0., 1., 1., 0.,
    ]);
    material.transmission = [1., 0.2, 0., 0., 1., 1., 1., 0.];
    frame.meshes.push(glass);

    for roughness in [0.05, 0.0501, 0.3, 0.59, 0.6] {
        frame.meshes[0].pbr.as_mut().unwrap().roughness = roughness;
        let actual = renderer.render(&frame, 96, 96).unwrap();
        let expected = reference.render(&frame, 96, 96).unwrap();
        frame.geometries.clear();
        assert_eq!(
            actual, expected,
            "roughness {roughness}: lit seed differs from redraw"
        );
        assert_eq!(
            renderer.profile.borrow().passes["screenLightingSource"].draw_calls,
            Some(2)
        );
        assert_eq!(
            renderer.profile.borrow().passes["transmission"].draw_calls,
            Some(2)
        );
        assert_eq!(
            renderer.profile.borrow().passes["scene"].draw_calls,
            Some(2)
        );
        println!("source/transmission/main 2/2/2, seeded=redraw at filtered roughness {roughness}");
    }
    let old = renderer
        .screen_lighting
        .targets
        .as_ref()
        .unwrap()
        .color
        .texture()
        .clone();
    let bytes = renderer.screen_lighting.bytes();
    assert!(
        renderer
            .render(&frame, 4096, 4096)
            .unwrap_err()
            .contains("Screen-space lighting exceeds")
    );
    assert_eq!(renderer.screen_lighting.bytes(), bytes);
    assert_eq!(
        renderer
            .screen_lighting
            .targets
            .as_ref()
            .unwrap()
            .color
            .texture(),
        &old
    );
    assert!(renderer.draw_cache.borrow().references_texture(&old));
}

fn compute_read(
    renderer: &Renderer,
    source: String,
    inputs: &[(u32, &wgpu::TextureView)],
    bytes: u64,
    groups: u32,
) -> Vec<u8> {
    let device = &renderer.device;
    let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("screen lighting regression"),
        source: wgpu::ShaderSource::Wgsl(source.into()),
    });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: None,
        layout: None,
        module: &shader,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });
    let output = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: bytes,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
        mapped_at_creation: false,
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: None,
        size: bytes,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let mut entries = vec![wgpu::BindGroupEntry {
        binding: 0,
        resource: output.as_entire_binding(),
    }];
    entries.extend(inputs.iter().map(|(binding, view)| wgpu::BindGroupEntry {
        binding: *binding,
        resource: wgpu::BindingResource::TextureView(view),
    }));
    let bind = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &pipeline.get_bind_group_layout(0),
        entries: &entries,
    });
    let mut encoder = device.create_command_encoder(&Default::default());
    {
        let mut pass = encoder.begin_compute_pass(&Default::default());
        pass.set_pipeline(&pipeline);
        pass.set_bind_group(0, &bind, &[]);
        pass.dispatch_workgroups(groups, 1, 1);
    }
    encoder.copy_buffer_to_buffer(&output, 0, &readback, 0, bytes);
    renderer.queue.submit([encoder.finish()]);
    let (tx, rx) = std::sync::mpsc::channel();
    readback
        .slice(..)
        .map_async(wgpu::MapMode::Read, move |r| tx.send(r).unwrap());
    device
        .poll(wgpu::PollType::Wait {
            submission_index: None,
            timeout: None,
        })
        .unwrap();
    rx.recv().unwrap().unwrap();
    readback.slice(..).get_mapped_range().unwrap().to_vec()
}
fn read_radiance(renderer: &Renderer, texture: &wgpu::TextureView) -> Vec<f32> {
    let n = texture.texture().width() * texture.texture().height();
    let bytes = compute_read(
        renderer,
        format!(
            r#"
@group(0) @binding(0) var<storage,read_write> result:array<vec4<f32>>;
@group(0) @binding(1) var source:texture_2d<f32>;
@compute @workgroup_size(64) fn main(@builtin(global_invocation_id) id:vec3<u32>) {{
 if(id.x>={n}u) {{return;}}
 let w=textureDimensions(source).x;
 result[id.x]=textureLoad(source,vec2<i32>(i32(id.x%w),i32(id.x/w)),0);
}}
"#
        ),
        &[(1, texture)],
        u64::from(n) * 16,
        n.div_ceil(64),
    );
    bytes
        .chunks_exact(4)
        .map(|v| f32::from_le_bytes(v.try_into().unwrap()))
        .collect()
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn glossy_source_load_count_is_independent_of_brdf() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture();
    frame.settings.screen_lighting = Some(Settings {
        reflections: true,
        ..Default::default()
    });
    renderer.render(&frame, 96, 96).unwrap();
    let targets = renderer.screen_lighting.targets.as_ref().unwrap();
    let body = include_str!("screen_lighting.wgsl")
        .split("fn screen_reflection")
        .next()
        .unwrap()
        .replace(
            "return textureLoad(screen_radiance",
            "atomicAdd(&result.loads,1u); return textureLoad(screen_radiance",
        )
        .replace(
            "sum+=textureLoad(screen_radiance",
            "atomicAdd(&result.loads,1u); sum+=textureLoad(screen_radiance",
        );
    for (roughness, expected) in [(0.05, 1), (0.0501, 4)] {
        let shader = format!(
            r#"
struct U {{capture_projection:mat4x4<f32>,inverse_view_projection:mat4x4<f32>,clipping:vec4<f32>}}
var<private> uniforms:U;
struct Result {{color:vec4<f32>,loads:atomic<u32>,pad:vec3<u32>}}
@group(0) @binding(0) var<storage,read_write> result:Result;
{body}
@compute @workgroup_size(1) fn main() {{
 uniforms.inverse_view_projection=mat4x4<f32>(vec4(1.,0.,0.,0.),vec4(0.,1.,0.,0.),vec4(0.,0.,1.,0.),vec4(0.,0.,0.,1.));
 let pixel=vec2<i32>(48,48); let depth=textureLoad(screen_depth,pixel,0);
 result.color=vec4(screen_hit_color(pixel,screen_position(pixel,depth),{roughness},1.),1.);
}}
"#
        );
        // The production depth rejection still executes; the uniform provides its tolerance.
        let shader = shader.replace("screen_lighting.reflection.y", "1.");
        let bytes = compute_read(
            &renderer,
            shader,
            &[(17, &targets.color), (18, &targets.depth)],
            48,
            1,
        );
        let loads = u32::from_le_bytes(bytes[16..20].try_into().unwrap());
        assert_eq!(loads, expected);
        println!("roughness={roughness}: production source loads={loads}");
    }
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn scaled_capture_keeps_source_primitive_footprints_and_ao_locations() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame = fixture();
    frame.meshes[0].pbr.as_mut().unwrap().metallic = 0.;
    frame.meshes[1].model =
        glam::Mat4::from_translation(glam::Vec3::new(0.6, 0., 0.)).to_cols_array();
    frame.hemispheres = vec![
        serde_json::from_value(
            json!({"sky_color":[1,1,1],"ground_color":[1,1,1],"direction":[0,1,0],"intensity":2}),
        )
        .unwrap(),
    ];
    frame.settings.screen_lighting = Some(Settings {
        ao: true,
        radius: 2.,
        quality: 2,
        ..Default::default()
    });
    let mut glass = frame.meshes[1].clone();
    glass.model = glam::Mat4::from_translation(glam::Vec3::new(0., 0., 1.)).to_cols_array();
    glass.pbr.as_mut().unwrap().physical = Some([
        1.5, 1., 0., 0., 1., 1., 1., 1., 0., 0., 0., 0., 0., 1., 1., 0.,
    ]);
    glass.pbr.as_mut().unwrap().transmission = [1., 0.2, 0., 0., 1., 1., 1., 0.];
    frame.meshes.push(glass);
    for topology in [1, 3] {
        let geometry:crate::scene::Geometry=serde_json::from_value(json!({"id":10+topology,"topology":topology,"positions":[[-0.6,0.,-3.],[-0.3,0.4,-3.]],"normals":[[0,0,1],[0,0,1]],"indices":if topology==1 {vec![0,1]} else {vec![0,1]}})).unwrap();
        frame.geometries.push(geometry);
        frame.meshes.push(crate::scene::Mesh {
            geometry: 10 + topology,
            primitive_kind: if topology == 1 { 1 } else { 2 },
            primitive_size: 5.,
            unlit: true,
            color: [0., 1., 0.],
            ..Default::default()
        });
    }
    renderer.render(&frame, 96, 96).unwrap();
    let source = read_radiance(
        &renderer,
        &renderer.screen_lighting.targets.as_ref().unwrap().color,
    );
    let full = read_radiance(
        &renderer,
        &renderer.transmission.targets.as_ref().unwrap().color,
    );
    frame.geometries.clear();
    frame.settings.opaque_capture_scale = 0.5;
    renderer.render(&frame, 96, 96).unwrap();
    assert_eq!(
        source,
        read_radiance(
            &renderer,
            &renderer.screen_lighting.targets.as_ref().unwrap().color
        )
    );
    let half = read_radiance(
        &renderer,
        &renderer.transmission.targets.as_ref().unwrap().color,
    );
    frame.settings.screen_lighting.as_mut().unwrap().ao = false;
    renderer.render(&frame, 96, 96).unwrap();
    let half_clear = read_radiance(
        &renderer,
        &renderer.transmission.targets.as_ref().unwrap().color,
    );
    frame.settings.opaque_capture_scale = 1.;
    renderer.render(&frame, 96, 96).unwrap();
    let full_clear = read_radiance(
        &renderer,
        &renderer.transmission.targets.as_ref().unwrap().color,
    );
    let mut error = 0.;
    let mut signal = 0.;
    let mut count = 0;
    for y in 30..43 {
        for x in 5..43 {
            let i = (y * 48 + x) * 4;
            let j = ((2 * y + 1) * 96 + 2 * x + 1) * 4;
            let a = half_clear[i] - half[i];
            let b = full_clear[j] - full[j];
            error += (a - b).abs();
            signal += b.abs();
            count += 1;
        }
    }
    println!(
        "scaled AO-only receiver mean error={}, signal={}",
        error / count as f32,
        signal / count as f32
    );
    assert!(signal / (count as f32) > 0.002);
    assert!(error / (count as f32) < 0.005);
    frame.settings.screen_lighting.as_mut().unwrap().ao = true;
    frame.settings.opaque_capture_scale = 0.5;
    renderer.render(&frame, 96, 96).unwrap();
    renderer.render(&frame, 96, 96).unwrap();
    assert_eq!(renderer.profile.borrow().draw_uniform_write_bytes, Some(0));
    let retained = renderer.scene_resource_stats().0;
    frame.settings.screen_lighting = None;
    renderer.render(&frame, 96, 96).unwrap();
    assert!(renderer.scene_resource_stats().0 < retained);
}
