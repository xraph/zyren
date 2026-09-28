use crate::render_graph::materials::{MaterialStore, PreparedMaterial};
use crate::scene::{Frame, Mesh};
use std::collections::HashMap;

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub(super) struct PipelineKey {
    format: wgpu::TextureFormat,
    shader: Option<[u64; 4]>,
    textured: bool,
    standard: bool,
    pub(super) tangents: bool,
    side: u32,
    mirrored: bool,
    blend: bool,
    primitive_kind: u32,
    depth_test: bool,
    depth_write: bool,
}
impl PipelineKey {
    pub(super) fn new(format: wgpu::TextureFormat, mesh: &Mesh, tangents: bool) -> Self {
        Self {
            format,
            shader: mesh.shader,
            textured: mesh.material_maps().next().is_some(),
            standard: mesh.pbr.is_some(),
            tangents: tangents && mesh.pbr.is_some() && mesh.material_maps().next().is_some(),
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
    standard_shader: wgpu::ShaderModule,
    standard_plain: wgpu::PipelineLayout,
    standard_textured: wgpu::PipelineLayout,
    plain: wgpu::PipelineLayout,
    textured: wgpu::PipelineLayout,
    cache: HashMap<PipelineKey, wgpu::RenderPipeline>,
}
impl MeshPipelines {
    pub(super) fn new(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        texture_layout: &wgpu::BindGroupLayout,
        pbr_layout: &wgpu::BindGroupLayout,
        pbr_texture_layout: &wgpu::BindGroupLayout,
        environment_layout: &wgpu::BindGroupLayout,
    ) -> Self {
        Self {
            standard_shader: device.create_shader_module(wgpu::include_wgsl!("pbr.wgsl")),
            standard_plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("standard"),
                bind_group_layouts: &[
                    Some(layout),
                    Some(pbr_layout),
                    Some(pbr_texture_layout),
                    Some(environment_layout),
                ],
                ..Default::default()
            }),
            standard_textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("standard textured"),
                bind_group_layouts: &[
                    Some(layout),
                    Some(pbr_layout),
                    Some(pbr_texture_layout),
                    Some(environment_layout),
                ],
                ..Default::default()
            }),
            shader: device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("native mesh materials"),
                source: wgpu::ShaderSource::Wgsl(
                    concat!(
                        include_str!("../mesh.wgsl"),
                        "\n",
                        include_str!("primitives.wgsl")
                    )
                    .into(),
                ),
            }),
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
            cache: HashMap::new(),
        }
    }
    pub(super) fn prepare(
        &mut self,
        device: &wgpu::Device,
        frame: &Frame,
        format: wgpu::TextureFormat,
        materials: &MaterialStore,
        geometries: &HashMap<u32, super::GpuGeometry>,
    ) -> Result<(), String> {
        self.retire_materials(materials);
        for mesh in &frame.meshes {
            if let Some(key) = mesh.shader {
                let material = materials.resolve(key).map_err(|e| e.to_string())?;
                if material.requires_uv
                    && frame
                        .geometries
                        .iter()
                        .find(|g| g.id == mesh.geometry)
                        .is_some_and(|g| g.uv0.is_empty() && g.uv1.is_empty())
                {
                    return Err("Material shader requires UV attributes".into());
                }
            }
        }
        if frame.meshes.iter().all(|mesh| {
            self.cache.contains_key(&PipelineKey::new(
                format,
                mesh,
                !geometries[&mesh.geometry].recipe.tangents.is_empty(),
            ))
        }) {
            return Ok(());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let mut pending = HashMap::new();
        for mesh in &frame.meshes {
            let key = PipelineKey::new(
                format,
                mesh,
                !geometries[&mesh.geometry].recipe.tangents.is_empty(),
            );
            if !self.cache.contains_key(&key) && !pending.contains_key(&key) {
                let pipeline = if let Some(value) = mesh.shader {
                    material_pipeline(
                        device,
                        materials.resolve(value).expect("validated shader"),
                        format,
                        mesh,
                    )
                } else {
                    self.create(device, key)
                };
                pending.insert(key, pipeline);
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
            None => {
                self.cache.extend(pending);
                Ok(())
            }
        }
    }
    pub(super) fn retire_materials(&mut self, materials: &MaterialStore) {
        self.cache
            .retain(|key, _| key.shader.is_none_or(|value| materials.contains(value)));
    }
    pub(super) fn get(&self, key: PipelineKey) -> &wgpu::RenderPipeline {
        &self.cache[&key]
    }
    fn create(&self, device: &wgpu::Device, key: PipelineKey) -> wgpu::RenderPipeline {
        if key.standard {
            return create_pipeline(
                device,
                key,
                ShaderPipeline {
                    module: &self.standard_shader,
                    layout: if key.textured {
                        &self.standard_textured
                    } else {
                        &self.standard_plain
                    },
                    requires_uv: key.textured,
                    vertex: if key.tangents {
                        "vertex_tangent"
                    } else if key.textured {
                        "vertex_textured"
                    } else {
                        "vertex"
                    },
                    fragment: if key.textured {
                        "fragment_textured"
                    } else {
                        "fragment"
                    },
                },
            );
        }
        create_pipeline(
            device,
            key,
            ShaderPipeline {
                module: &self.shader,
                layout: if key.textured {
                    &self.textured
                } else {
                    &self.plain
                },
                requires_uv: key.textured,
                vertex: if key.primitive_kind == 1 {
                    "vs_line"
                } else if key.primitive_kind == 2 {
                    "vs_point"
                } else if key.textured {
                    "vs_textured"
                } else {
                    "vs_main"
                },
                fragment: if key.primitive_kind != 0 {
                    "fs_primitive"
                } else if key.textured {
                    "fs_textured"
                } else {
                    "fs_main"
                },
            },
        )
    }
}
struct ShaderPipeline<'a> {
    module: &'a wgpu::ShaderModule,
    layout: &'a wgpu::PipelineLayout,
    requires_uv: bool,
    vertex: &'a str,
    fragment: &'a str,
}
pub(crate) fn material_pipeline(
    device: &wgpu::Device,
    material: &PreparedMaterial,
    format: wgpu::TextureFormat,
    mesh: &Mesh,
) -> wgpu::RenderPipeline {
    create_pipeline(
        device,
        PipelineKey::new(format, mesh, false),
        ShaderPipeline {
            module: &material.shader,
            layout: &material.layout,
            requires_uv: material.requires_uv,
            vertex: &material.vertex,
            fragment: &material.fragment,
        },
    )
}
fn create_pipeline(
    device: &wgpu::Device,
    key: PipelineKey,
    shader: ShaderPipeline<'_>,
) -> wgpu::RenderPipeline {
    let attributes = wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3];
    let tangent_attributes = wgpu::vertex_attr_array![4 => Float32x4];
    let uv_attributes = wgpu::vertex_attr_array![2 => Float32x2, 3 => Float32x2];
    let mut buffers = vec![Some(wgpu::VertexBufferLayout {
        array_stride: 24,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &attributes,
    })];
    if shader.requires_uv {
        buffers.push(Some(wgpu::VertexBufferLayout {
            array_stride: 16,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &uv_attributes,
        }));
    }
    if key.tangents {
        buffers.push(Some(wgpu::VertexBufferLayout {
            array_stride: 16,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &tangent_attributes,
        }));
    }
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("native mesh state"),
        layout: Some(shader.layout),
        vertex: wgpu::VertexState {
            module: shader.module,
            entry_point: Some(shader.vertex),
            compilation_options: Default::default(),
            buffers: &buffers,
        },
        fragment: Some(wgpu::FragmentState {
            module: shader.module,
            entry_point: Some(shader.fragment),
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
            cull_mode: match key.side {
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
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    })
}
