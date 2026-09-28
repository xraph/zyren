use super::*;

pub(super) fn layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    let mut entries: Vec<_> = [64, 1312, 784]
        .into_iter()
        .enumerate()
        .map(|(binding, size)| wgpu::BindGroupLayoutEntry {
            binding: binding as u32,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: wgpu::BufferSize::new(size),
            },
            count: None,
        })
        .collect();
    entries.push(wgpu::BindGroupLayoutEntry {
        binding: 3,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Depth,
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    });
    entries.push(wgpu::BindGroupLayoutEntry {
        binding: 4,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Comparison),
        count: None,
    });
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("physical material and lights"),
        entries: &entries,
    })
}
impl Renderer {
    pub(super) fn lighting_bindings(&self, frame: &Frame) -> Vec<Option<wgpu::BindGroup>> {
        if frame.meshes.iter().all(|m| m.pbr.is_none()) {
            return vec![None; frame.meshes.len()];
        }
        let (shadow_buffer, shadow_view) = self.shadows.globals(&self.device, frame);
        let mut lights = [0_f32; 328];
        lights[0] = frame.lights.len() as f32;
        let inverse = Mat4::from_cols_array(&frame.view_projection).inverse();
        let direction =
            (inverse.project_point3(glam::Vec3::new(0., 0., frame.settings.depth_near()))
                - inverse.project_point3(glam::Vec3::new(0., 0., 0.5)))
            .normalize();
        lights[4..7].copy_from_slice(&direction.to_array());
        lights[7] = if frame.view_projection[15] == 1. {
            1.
        } else {
            0.
        };
        for (index, values) in frame.lights.iter().enumerate() {
            lights[8 + index * 20..8 + (index + 1) * 20].copy_from_slice(values);
        }
        let light_buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("physical lights"),
                contents: bytemuck::cast_slice(&lights),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        frame
            .meshes
            .iter()
            .map(|mesh| {
                mesh.pbr.map(|p| {
                    let mut flags = u32::from(mesh.color_map.is_some());
                    for (i, map) in mesh.pbr_maps.iter().enumerate() {
                        if map.is_some() {
                            flags |= 1 << (i + 1);
                        }
                    }
                    let uv: Vec<_> = mesh
                        .pbr_maps
                        .iter()
                        .map(|map| map.as_ref().map_or(0., |m| m.uv_set as f32))
                        .collect();
                    let values = [
                        p[0],
                        p[1],
                        p[2],
                        if mesh.shadow_flags & 2 != 0 { 1. } else { 0. },
                        p[3],
                        p[4],
                        p[5],
                        0.,
                        mesh.pbr_scales[0],
                        mesh.pbr_scales[1],
                        mesh.pbr_scales[2],
                        flags as f32,
                        uv[0],
                        uv[1],
                        uv[2],
                        uv[3],
                    ];
                    let buffer =
                        self.device
                            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                                label: Some("physical material"),
                                contents: bytemuck::cast_slice(&values),
                                usage: wgpu::BufferUsages::UNIFORM,
                            });
                    self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("physical material"),
                        layout: &self.pbr_layout,
                        entries: &[
                            wgpu::BindGroupEntry {
                                binding: 2,
                                resource: shadow_buffer.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 3,
                                resource: wgpu::BindingResource::TextureView(&shadow_view),
                            },
                            wgpu::BindGroupEntry {
                                binding: 4,
                                resource: wgpu::BindingResource::Sampler(&self.shadows.sampler),
                            },
                            wgpu::BindGroupEntry {
                                binding: 0,
                                resource: buffer.as_entire_binding(),
                            },
                            wgpu::BindGroupEntry {
                                binding: 1,
                                resource: light_buffer.as_entire_binding(),
                            },
                        ],
                    })
                })
            })
            .collect()
    }
}
