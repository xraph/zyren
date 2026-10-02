use glam::{Mat3, Mat4, Quat, Vec3};
use wgpu::util::DeviceExt;
use zyren_runtime::{
    deformation::{MorphTarget, Pose},
    scene::Geometry,
};

fn geometry() -> Geometry {
    let mut g: Geometry = serde_json::from_value(serde_json::json!({"id":1,
        "positions":[[-0.5,-0.5,0],[0.5,-0.5,0],[0,0.5,0]],
        "normals":[[0.2,0.3,1],[0,0,1],[0,0,1]],"indices":[0,1,2],
        "tangents":[[1,0.2,0,1],[1,0,0,-1],[1,0,0,1]],
        "joints":[[0,1,0,1],[0,1,0,1],[1,0,1,0]],
        "weights":[[0.2,0.4,0.6,0.8],[0.5,0.5,0,0],[2,0,0,0]]
    }))
    .unwrap();
    g.morphs = vec![
        MorphTarget {
            positions: vec![[0.1, 0.2, 0.3]; 3],
            normals: vec![[0.2, -0.1, 0.05]; 3],
            tangents: vec![[0.1, 0.3, 0.2]; 3],
        },
        MorphTarget {
            positions: vec![[0.3, -0.1, 0.1]; 3],
            ..Default::default()
        },
    ];
    g
}
fn pose(reflected: bool) -> Pose {
    Pose {
        id: 1,
        geometry: 1,
        weights: vec![-0.25, 1.4],
        matrices: vec![
            Mat4::from_scale_rotation_translation(
                Vec3::new(0.7, 1.5, 1.2),
                Quat::from_rotation_z(0.4),
                Vec3::new(0.1, -0.2, 0.3),
            )
            .to_cols_array(),
            Mat4::from_scale_rotation_translation(
                Vec3::new(if reflected { -1.8 } else { 1.8 }, 0.6, 1.4),
                Quat::from_rotation_x(-0.6),
                Vec3::new(-0.2, 0.4, 0.1),
            )
            .to_cols_array(),
        ],
    }
}
#[test]
fn deformation_admission_checks_streams_palettes_and_finite_affine_matrices() {
    let mut g = geometry();
    let mut p = pose(false);
    g.validate().unwrap();
    p.validate(&g).unwrap();
    assert_eq!(g.deformation_values().len() * 4, g.deformation_bytes());
    assert_eq!(p.gpu_values(&g).len() * 4, p.byte_length());
    p.matrices[0][3] = 0.1;
    assert!(p.validate(&g).is_err());
    p = pose(false);
    p.matrices[0][0] = f32::NAN;
    assert!(p.validate(&g).is_err());
    p = pose(false);
    p.weights[0] = f32::INFINITY;
    assert!(p.validate(&g).is_err());
    p = pose(false);
    g.joints[0][3] = 2;
    assert!(p.validate(&g).is_err());
    g = geometry();
    g.weights[0] = [0.; 4];
    assert!(g.validate().is_err());
    g = geometry();
    g.weights[0][0] = -0.1;
    assert!(g.validate().is_err());
    g = geometry();
    g.morphs[0].normals.pop();
    assert!(g.validate().is_err());
}

#[test]
#[ignore = "requires a native GPU"]
fn shader_positions_normals_and_tangents_match_independent_cpu_oracle() {
    pollster::block_on(async {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL | wgpu::Backends::VULKAN | wgpu::Backends::DX12,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = instance.request_adapter(&Default::default()).await.unwrap();
        let (device, queue) = adapter.request_device(&Default::default()).await.unwrap();
        let source = format!(
            "{}\n{}",
            include_str!("../src/deformation.wgsl"),
            r#"
@group(0) @binding(0) var<storage,read> inputs: array<vec4<f32>>;
@group(0) @binding(1) var<storage,read_write> outputs: array<vec4<f32>>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) invocation: vec3<u32>) {
 let i=invocation.x;
 let d=deform_vertex(i,inputs[i*3u].xyz,inputs[i*3u+1u].xyz,inputs[i*3u+2u]);
 outputs[i*3u]=vec4(d.position,1.); outputs[i*3u+1u]=vec4(d.normal,0.); outputs[i*3u+2u]=d.tangent;
}"#
        );
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("deformation numeric oracle"),
            source: wgpu::ShaderSource::Wgsl(source.into()),
        });
        let storage_layout = |write: bool| {
            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: None,
                entries: &[0, 1].map(|binding| wgpu::BindGroupLayoutEntry {
                    binding,
                    visibility: wgpu::ShaderStages::COMPUTE,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Storage {
                            read_only: !write || binding == 0,
                        },
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                }),
            })
        };
        let io_layout = storage_layout(true);
        let deform_layout = storage_layout(false);
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[Some(&io_layout), None, Some(&deform_layout)],
            ..Default::default()
        });
        let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
            label: None,
            layout: Some(&layout),
            module: &shader,
            entry_point: Some("main"),
            compilation_options: Default::default(),
            cache: None,
        });
        let g = geometry();
        let inputs: Vec<f32> = (0..3)
            .flat_map(|i| {
                g.positions[i]
                    .into_iter()
                    .chain([1.])
                    .chain(g.normals[i])
                    .chain([0.])
                    .chain(g.tangents[i])
            })
            .collect();
        let buffer = |bytes: &[u8]| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: None,
                contents: bytes,
                usage: wgpu::BufferUsages::STORAGE,
            })
        };
        let input = buffer(bytemuck::cast_slice(&inputs));
        let geometry_buffer = buffer(bytemuck::cast_slice(&g.deformation_values()));
        let output = device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: 144,
            usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC,
            mapped_at_creation: false,
        });
        let readback = device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: 144,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let bind = |layout: &wgpu::BindGroupLayout, a: &wgpu::Buffer, b: &wgpu::Buffer| {
            device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: None,
                layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: a.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: b.as_entire_binding(),
                    },
                ],
            })
        };
        let io = bind(&io_layout, &input, &output);
        for reflected in [false, true] {
            let p = pose(reflected);
            p.validate(&g).unwrap();
            let pose_buffer = buffer(bytemuck::cast_slice(&p.gpu_values(&g)));
            let deformation = bind(&deform_layout, &geometry_buffer, &pose_buffer);
            let mut encoder = device.create_command_encoder(&Default::default());
            {
                let mut pass = encoder.begin_compute_pass(&Default::default());
                pass.set_pipeline(&pipeline);
                pass.set_bind_group(0, &io, &[]);
                pass.set_bind_group(2, &deformation, &[]);
                pass.dispatch_workgroups(3, 1, 1);
            }
            encoder.copy_buffer_to_buffer(&output, 0, &readback, 0, 144);
            queue.submit([encoder.finish()]);
            let (tx, rx) = std::sync::mpsc::channel();
            readback
                .slice(..)
                .map_async(wgpu::MapMode::Read, move |v| tx.send(v).unwrap());
            device.poll(wgpu::PollType::wait_indefinitely()).unwrap();
            rx.recv().unwrap().unwrap();
            let mapped = readback.slice(..).get_mapped_range().unwrap();
            let values: &[f32] = bytemuck::cast_slice(&mapped);
            for i in 0..3 {
                let mut pos = Vec3::from_array(g.positions[i]);
                let mut normal = Vec3::from_array(g.normals[i]);
                let mut tangent = Vec3::from_array(g.tangents[i][..3].try_into().unwrap());
                for (m, w) in g.morphs.iter().zip(&p.weights) {
                    if !m.positions.is_empty() {
                        pos += Vec3::from_array(m.positions[i]) * *w;
                    }
                    if !m.normals.is_empty() {
                        normal += Vec3::from_array(m.normals[i]) * *w;
                    }
                    if !m.tangents.is_empty() {
                        tangent += Vec3::from_array(m.tangents[i]) * *w;
                    }
                }
                let total: f32 = g.weights[i].iter().sum();
                let mut matrix = Mat4::ZERO;
                for j in 0..4 {
                    matrix += Mat4::from_cols_array(&p.matrices[g.joints[i][j] as usize])
                        * (g.weights[i][j] / total);
                }
                let linear = Mat3::from_mat4(matrix);
                let pos = matrix.transform_point3(pos);
                let normal = linear.inverse().transpose() * normal;
                let tangent = linear * tangent;
                let expected: Vec<f32> = pos
                    .to_array()
                    .into_iter()
                    .chain([1.])
                    .chain(normal.to_array())
                    .chain([0.])
                    .chain(tangent.to_array())
                    .chain([g.tangents[i][3] * linear.determinant().signum()])
                    .collect();
                for (component, (actual, expected)) in
                    values[i * 12..i * 12 + 12].iter().zip(expected).enumerate()
                {
                    assert!(
                        (actual - expected).abs() < 1e-5,
                        "reflection {reflected}, vertex {i}, component {component}: GPU {actual}, CPU {expected}"
                    );
                }
            }
            drop(mapped);
            readback.unmap();
        }
    });
}

#[test]
#[ignore = "requires a native GPU"]
fn invalid_poses_preserve_pixels_ownership_and_resource_accounting() {
    use zyren_runtime::{renderer::Renderer, scene::Frame, scene_packet::ViewState};
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let mut frame:Frame=serde_json::from_value(serde_json::json!({
        "version":1,"view_projection":Mat4::IDENTITY.to_cols_array(),"background":[0,0,0],"light_direction":[0,0,1],"ambient":0.1,
        "geometries":[],"meshes":[{"geometry":1,"model":Mat4::IDENTITY.to_cols_array(),"color":[1,0,0],"unlit":true}]
    })).unwrap();
    frame.geometries.push(geometry());
    frame.poses.push(pose(false));
    frame.meshes[0].pose = 1;
    frame.binary = Some(ViewState {
        view: 81,
        revision: 1,
        retained: [1].into(),
        meshes: frame.meshes.clone(),
        retained_textures: Default::default(),
        retained_instances: Default::default(),
        retained_poses: [1].into(),
    });
    let expected_bytes = frame.geometries[0].byte_length() + frame.poses[0].byte_length();
    let pixels = renderer.render(&frame, 31, 31).unwrap();
    let stats = renderer.scene_resource_stats();
    assert_eq!(stats, (expected_bytes as u64, expected_bytes as u64));
    frame.geometries.clear();
    frame.poses.clear();
    let mut missing = frame.clone();
    let mut missing_pose = pose(false);
    missing_pose.id = 9;
    missing_pose.geometry = 99;
    missing.poses.push(missing_pose);
    assert!(renderer.render(&missing, 31, 31).is_err());
    let mut invalid = frame.clone();
    invalid.poses.push(pose(true));
    assert!(renderer.render(&invalid, 31, 31).is_err());
    let mut invalid = frame.clone();
    invalid.binary.as_mut().unwrap().retained.clear();
    invalid.meshes.clear();
    assert!(renderer.render(&invalid, 31, 31).is_err());
    let mut invalid = frame.clone();
    invalid.meshes[0].pose = 2;
    invalid.binary.as_mut().unwrap().retained_poses = [2].into();
    let mut p = pose(false);
    p.id = 2;
    p.matrices[1] = [0.; 16];
    invalid.poses.push(p);
    assert!(renderer.render(&invalid, 31, 31).is_err());
    assert_eq!(renderer.render(&frame, 31, 31).unwrap(), pixels);
    assert_eq!(renderer.scene_resource_stats(), stats);
    renderer.close_scene_view(81).unwrap();
    assert_eq!(renderer.scene_resource_stats().0, 0);
}
