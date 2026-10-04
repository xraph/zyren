//! Opaque frame inputs for opted-in custom surfaces. No user-owned texture handle
//! escapes the current view. Capture completes before any consumer draw.
use super::{Renderer, draw_cache};
use crate::{render_graph::PreparedMaterial, scene::Frame};
use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Uniforms {
    inverse_view_projection: [f32; 16],
    viewport: [f32; 4],
    depth: [f32; 4],
}
pub(super) const UNIFORM_BYTES: usize = std::mem::size_of::<Uniforms>();
pub(crate) fn layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("custom surface opaque inputs"),
        entries: &[
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(UNIFORM_BYTES as u64),
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 2,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Depth,
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
        ],
    })
}
impl Renderer {
    pub(super) fn scene_input_bindings(
        &self,
        frame: &Frame,
        size: [u32; 2],
        materials: &[Option<PreparedMaterial>],
    ) -> Vec<Option<wgpu::BindGroup>> {
        if !frame
            .meshes
            .iter()
            .any(|m| m.color_visible && m.scene_inputs)
        {
            return vec![None; frame.meshes.len()];
        }
        let targets = self
            .transmission
            .targets
            .as_ref()
            .expect("admitted opaque capture");
        let uniforms = Uniforms {
            inverse_view_projection: glam::Mat4::from_cols_array(&self.temporal.vp(frame))
                .inverse()
                .to_cols_array(),
            viewport: [
                size[0] as f32,
                size[1] as f32,
                1. / size[0] as f32,
                1. / size[1] as f32,
            ],
            depth: [
                frame.settings.depth_clear(),
                if frame.settings.reversed_depth() {
                    1.
                } else {
                    0.
                },
                0.,
                0.,
            ],
        };
        let buffer = self.draw_uniform(
            draw_cache::UniformKey::SceneInputs,
            bytemuck::bytes_of(&uniforms),
        );
        frame
            .meshes
            .iter()
            .enumerate()
            .map(|(index, mesh)| {
                if !mesh.color_visible || !mesh.scene_inputs {
                    return None;
                }
                let layout = materials[index]
                    .as_ref()
                    .and_then(|m| m.scene_input_layout.as_ref())
                    .expect("compiled scene input layout");
                Some(self.draw_binding(
                    draw_cache::BindingKey(index, 4),
                    layout,
                    &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: buffer.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: wgpu::BindingResource::TextureView(&targets.color),
                        },
                        wgpu::BindGroupEntry {
                            binding: 2,
                            resource: wgpu::BindingResource::TextureView(&targets.depth),
                        },
                    ],
                ))
            })
            .collect()
    }
}
