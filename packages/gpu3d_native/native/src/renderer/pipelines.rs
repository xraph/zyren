use crate::scene::{Frame, Mesh};
use std::collections::HashMap;

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub(super) struct PipelineKey {
    format: wgpu::TextureFormat,
    textured: bool,
    blend: bool,
    depth_test: bool,
    depth_write: bool,
}
impl PipelineKey {
    pub(super) fn new(format: wgpu::TextureFormat, mesh: &Mesh) -> Self {
        Self {
            format,
            textured: mesh.color_map.is_some(),
            blend: mesh.alpha_mode == 2,
            depth_test: mesh.depth_test,
            depth_write: mesh.writes_depth(),
        }
    }
}
pub(super) struct MeshPipelines {
    shader: wgpu::ShaderModule,
    plain: wgpu::PipelineLayout,
    textured: wgpu::PipelineLayout,
    cache: HashMap<PipelineKey, wgpu::RenderPipeline>,
}
impl MeshPipelines {
    pub(super) fn new(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        texture_layout: &wgpu::BindGroupLayout,
    ) -> Self {
        Self {
            shader: device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("native mesh materials"),
                source: wgpu::ShaderSource::Wgsl(include_str!("../mesh.wgsl").into()),
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
    ) -> Result<(), String> {
        if frame
            .meshes
            .iter()
            .all(|mesh| self.cache.contains_key(&PipelineKey::new(format, mesh)))
        {
            return Ok(());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        for mesh in &frame.meshes {
            let key = PipelineKey::new(format, mesh);
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
    fn create(&self, device: &wgpu::Device, key: PipelineKey) -> wgpu::RenderPipeline {
        let attributes = wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3];
        let uv_attributes = wgpu::vertex_attr_array![2 => Float32x2, 3 => Float32x2];
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
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("native mesh state"),
            layout: Some(if key.textured {
                &self.textured
            } else {
                &self.plain
            }),
            vertex: wgpu::VertexState {
                module: &self.shader,
                entry_point: Some(if key.textured {
                    "vs_textured"
                } else {
                    "vs_main"
                }),
                compilation_options: Default::default(),
                buffers: &buffers,
            },
            fragment: Some(wgpu::FragmentState {
                module: &self.shader,
                entry_point: Some(if key.textured {
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
                cull_mode: None,
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
}
