use crate::scene::{Frame, Mesh};
use std::collections::HashMap;

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub(super) struct PipelineKey {
    format: wgpu::TextureFormat,
    sample_count: u32,
    textured: bool,
    standard: bool,
    tangent: bool,
    colored: bool,
    instanced: bool,
    deformed: bool,
    side: u32,
    mirrored: bool,
    blend: bool,
    primitive_kind: u32,
    depth_test: bool,
    depth_write: bool,
}
impl PipelineKey {
    pub(super) fn new(
        format: wgpu::TextureFormat,
        mesh: &Mesh,
        tangent: bool,
        sample_count: u32,
    ) -> Self {
        Self {
            format,
            sample_count,
            colored: mesh.vertex_colors,
            instanced: mesh.instances != 0,
            deformed: mesh.pose != 0,
            textured: mesh.texture_maps().next().is_some(),
            tangent: tangent
                && mesh.pbr.is_some()
                && (mesh.texture_maps().next().is_some() || mesh.anisotropic()),
            standard: mesh.pbr.is_some(),
            side: mesh.side,
            mirrored: mesh.primitive_kind == 0
                && glam::Mat4::from_cols_array(&mesh.model).determinant() < 0.,
            blend: mesh.alpha_mode == 2,
            primitive_kind: mesh.primitive_kind,
            depth_test: mesh.depth_test,
            depth_write: mesh.writes_depth(),
        }
    }
}
pub(super) struct MeshPipelines {
    shader: wgpu::ShaderModule,
    plain: wgpu::PipelineLayout,
    deformed_plain: wgpu::PipelineLayout,
    deformed_textured: wgpu::PipelineLayout,
    textured: wgpu::PipelineLayout,
    standard_plain: wgpu::PipelineLayout,
    deformed_standard_plain: wgpu::PipelineLayout,
    deformed_standard_textured: wgpu::PipelineLayout,
    standard_textured: wgpu::PipelineLayout,
    cache: HashMap<PipelineKey, wgpu::RenderPipeline>,
}
impl MeshPipelines {
    pub(super) fn new(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        pbr_layout: &wgpu::BindGroupLayout,
        texture_layout: &wgpu::BindGroupLayout,
        standard_texture_layout: &wgpu::BindGroupLayout,
        deformation_layout: &wgpu::BindGroupLayout,
    ) -> Self {
        Self {
            shader: device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("native mesh materials"),
                source: wgpu::ShaderSource::Wgsl(
                    concat!(
                        include_str!("../mesh.wgsl"),
                        "\n",
                        include_str!("../deformation.wgsl"),
                        "\n",
                        include_str!("../deformation_mesh.wgsl"),
                        "\n",
                        include_str!("primitives.wgsl"),
                        "\n",
                        include_str!("pbr.wgsl"),
                        "\n",
                        include_str!("physical.wgsl"),
                        "\n",
                        include_str!("area_lights.wgsl"),
                        "\n",
                        include_str!("shadow_sampling.wgsl")
                    )
                    .into(),
                ),
            }),
            deformed_plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("deformed triangles"),
                bind_group_layouts: &[Some(layout), None, Some(deformation_layout)],
                ..Default::default()
            }),
            deformed_textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("deformed triangles"),
                bind_group_layouts: &[Some(layout), Some(texture_layout), Some(deformation_layout)],
                ..Default::default()
            }),
            deformed_standard_plain: device.create_pipeline_layout(
                &wgpu::PipelineLayoutDescriptor {
                    label: Some("deformed triangles"),
                    bind_group_layouts: &[Some(pbr_layout), None, Some(deformation_layout)],
                    ..Default::default()
                },
            ),
            deformed_standard_textured: device.create_pipeline_layout(
                &wgpu::PipelineLayoutDescriptor {
                    label: Some("deformed triangles"),
                    bind_group_layouts: &[
                        Some(pbr_layout),
                        Some(standard_texture_layout),
                        Some(deformation_layout),
                    ],
                    ..Default::default()
                },
            ),
            plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[Some(layout)],
                ..Default::default()
            }),
            textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[Some(layout), Some(texture_layout)],
                ..Default::default()
            }),
            standard_plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("standard material"),
                bind_group_layouts: &[Some(pbr_layout)],
                ..Default::default()
            }),
            standard_textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("textured standard material"),
                bind_group_layouts: &[Some(pbr_layout), Some(standard_texture_layout)],
                ..Default::default()
            }),
            cache: HashMap::new(),
        }
    }
    pub(super) fn prepare(
        &mut self,
        device: &wgpu::Device,
        frame: &Frame,
        format: wgpu::TextureFormat,
        has_tangents: impl Fn(u32) -> bool,
    ) -> Result<(), String> {
        if frame.meshes.iter().all(|mesh| {
            mesh.shader.is_some()
                || self.cache.contains_key(&PipelineKey::new(
                    format,
                    mesh,
                    has_tangents(mesh.geometry),
                    frame.sample_count(),
                ))
        }) {
            return Ok(());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        for mesh in &frame.meshes {
            if mesh.shader.is_some() {
                continue;
            }
            let key = PipelineKey::new(
                format,
                mesh,
                has_tangents(mesh.geometry),
                frame.sample_count(),
            );
            if !self.cache.contains_key(&key) {
                let pipeline = self.create(device, key);
                self.cache.insert(key, pipeline);
            }
        }
        let mut error = None;
        for scope in [internal, memory, validation] {
            if let Some(failure) = pollster::block_on(scope.pop()) {
                error = Some(failure.to_string());
            }
        }
        match error {
            Some(error) => Err(error),
            None => Ok(()),
        }
    }
    pub(super) fn get(&self, key: PipelineKey) -> &wgpu::RenderPipeline {
        &self.cache[&key]
    }
    pub(super) fn len(&self) -> usize {
        self.cache.len()
    }
    fn create(&self, device: &wgpu::Device, key: PipelineKey) -> wgpu::RenderPipeline {
        let attributes = wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3];
        let uv_attributes = wgpu::vertex_attr_array![2 => Float32x2, 3 => Float32x2];
        let color_attributes = wgpu::vertex_attr_array![5=>Float32x4,6=>Float32x4];
        let instance_attributes = wgpu::vertex_attr_array![6=>Float32x4,7=>Float32x4,8=>Float32x4,9=>Float32x4,10=>Float32x4,11=>Float32x4,12=>Float32x4,13=>Float32x3];
        let tangent_attributes = wgpu::vertex_attr_array![4 => Float32x4];
        let mut buffers = vec![Some(wgpu::VertexBufferLayout {
            array_stride: 24,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &attributes,
        })];
        if key.textured {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: 16,
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: &uv_attributes,
            }));
        }
        if key.tangent {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: 16,
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: &tangent_attributes,
            }));
        }
        if key.colored {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: if key.primitive_kind == 0 { 16 } else { 32 },
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: if key.primitive_kind == 0 {
                    &color_attributes[..1]
                } else {
                    &color_attributes
                },
            }));
        }
        if key.instanced {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: crate::instances::INSTANCE_STRIDE as u64,
                step_mode: wgpu::VertexStepMode::Instance,
                attributes: &instance_attributes,
            }));
        }
        let vertex_entry = if key.instanced {
            match (key.tangent, key.textured, key.colored) {
                (true, false, true) => "vs_instance_standard_tangent_colored_unmapped",
                (true, false, false) => "vs_instance_standard_tangent_unmapped",
                (true, _, true) => "vs_instance_standard_tangent_colored",
                (true, _, false) => "vs_instance_standard_tangent",
                (_, true, true) => "vs_instance_textured_colored",
                (_, true, false) => "vs_instance_textured",
                (_, _, true) => "vs_instance_colored",
                _ => "vs_instance_main",
            }
        } else if key.primitive_kind == 1 {
            if key.colored {
                "vs_line_colored"
            } else {
                "vs_line"
            }
        } else if key.primitive_kind == 2 {
            if key.colored {
                "vs_point_colored"
            } else {
                "vs_point"
            }
        } else if key.tangent && !key.textured {
            if key.colored {
                "vs_standard_tangent_colored_unmapped"
            } else {
                "vs_standard_tangent_unmapped"
            }
        } else if key.tangent {
            if key.colored {
                "vs_standard_tangent_colored"
            } else {
                "vs_standard_tangent"
            }
        } else if key.textured {
            if key.colored {
                "vs_textured_colored"
            } else {
                "vs_textured"
            }
        } else {
            if key.colored { "vs_colored" } else { "vs_main" }
        };
        let vertex_entry = if key.deformed {
            format!("deformed_{vertex_entry}")
        } else {
            vertex_entry.to_owned()
        };
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("native mesh state"),
            layout: Some(if key.deformed {
                if key.standard && key.textured {
                    &self.deformed_standard_textured
                } else if key.standard {
                    &self.deformed_standard_plain
                } else if key.textured {
                    &self.deformed_textured
                } else {
                    &self.deformed_plain
                }
            } else if key.standard && key.textured {
                &self.standard_textured
            } else if key.standard {
                &self.standard_plain
            } else if key.textured {
                &self.textured
            } else {
                &self.plain
            }),
            vertex: wgpu::VertexState {
                module: &self.shader,
                entry_point: Some(&vertex_entry),
                compilation_options: Default::default(),
                buffers: &buffers,
            },
            fragment: Some(wgpu::FragmentState {
                module: &self.shader,
                entry_point: Some(if key.primitive_kind != 0 {
                    "fs_primitive"
                } else if key.standard && key.textured {
                    "fs_standard_textured"
                } else if key.standard {
                    "fs_standard"
                } else if key.textured {
                    "fs_textured"
                } else {
                    "fs_main"
                }),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: key.format,
                    blend: if key.blend {
                        Some(wgpu::BlendState::ALPHA_BLENDING)
                    } else {
                        None
                    },
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                front_face: if key.mirrored {
                    wgpu::FrontFace::Cw
                } else {
                    wgpu::FrontFace::Ccw
                },
                cull_mode: match if key.instanced { 0 } else { key.side } {
                    1 => Some(wgpu::Face::Back),
                    2 => Some(wgpu::Face::Front),
                    _ => None,
                },
                ..Default::default()
            },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: wgpu::TextureFormat::Depth32Float,
                depth_write_enabled: Some(key.depth_write),
                depth_compare: Some(if key.depth_test {
                    wgpu::CompareFunction::Less
                } else {
                    wgpu::CompareFunction::Always
                }),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: wgpu::MultisampleState {
                count: key.sample_count,
                ..Default::default()
            },
            multiview_mask: None,
            cache: None,
        })
    }
}
