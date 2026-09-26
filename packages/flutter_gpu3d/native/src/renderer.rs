use std::{
    collections::{HashMap, HashSet},
    sync::mpsc,
};

use bytemuck::{Pod, Zeroable};
use glam::Mat4;
use wgpu::util::DeviceExt;

use crate::scene::{Frame, pixel_len};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Vertex {
    position: [f32; 3],
    normal: [f32; 3],
}

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Uniforms {
    mvp: [f32; 16],
    normal_matrix: [f32; 16],
    color_unlit: [f32; 4],
    light_ambient: [f32; 4],
}

struct GpuGeometry {
    vertices: wgpu::Buffer,
    indices: wgpu::Buffer,
    count: u32,
    bytes: usize,
}
struct Targets {
    width: u32,
    height: u32,
    stride: u32,
    color: wgpu::Texture,
    color_view: wgpu::TextureView,
    _depth: wgpu::Texture,
    depth_view: wgpu::TextureView,
    readback: wgpu::Buffer,
}

pub struct Renderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    geometries: HashMap<u32, GpuGeometry>,
    targets: Option<Targets>,
    pub adapter_name: String,
    pub backend: wgpu::Backend,
}

impl Renderer {
    pub async fn new() -> Result<Self, String> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL | wgpu::Backends::VULKAN | wgpu::Backends::DX12,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: None,
                force_fallback_adapter: false,
                ..Default::default()
            })
            .await
            .map_err(|e| format!("no Metal, Vulkan or DX12 adapter: {e}"))?;
        let info = adapter.get_info();
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("flutter_gpu3d"),
                required_limits: wgpu::Limits {
                    max_texture_dimension_2d: crate::scene::MAX_DIMENSION,
                    ..wgpu::Limits::downlevel_defaults()
                },
                ..Default::default()
            })
            .await
            .map_err(|e| format!("device creation failed: {e}"))?;
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("native opaque mesh"),
            source: wgpu::ShaderSource::Wgsl(include_str!("mesh.wgsl").into()),
        });
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[Some(&layout)],
            ..Default::default()
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("opaque meshes"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[Some(wgpu::VertexBufferLayout {
                    array_stride: 24,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3],
                })],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8UnormSrgb,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                cull_mode: None,
                ..Default::default()
            },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: wgpu::TextureFormat::Depth32Float,
                depth_write_enabled: Some(true),
                depth_compare: Some(wgpu::CompareFunction::Less),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        Ok(Self {
            device,
            queue,
            pipeline,
            layout,
            geometries: HashMap::new(),
            targets: None,
            adapter_name: info.name,
            backend: info.backend,
        })
    }

    fn resize(&mut self, width: u32, height: u32) {
        if self
            .targets
            .as_ref()
            .is_some_and(|t| t.width == width && t.height == height)
        {
            return;
        }
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        let color = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("frame color"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let depth = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("frame depth"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let stride = (width * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT)
            * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("RGBA readback"),
            size: stride as u64 * height as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        self.targets = Some(Targets {
            width,
            height,
            stride,
            color_view: color.create_view(&Default::default()),
            color,
            depth_view: depth.create_view(&Default::default()),
            _depth: depth,
            readback,
        });
    }

    pub fn render(&mut self, frame: &Frame, width: u32, height: u32) -> Result<Vec<u8>, String> {
        let len = pixel_len(width, height)?;
        frame.validate(&self.geometries.keys().copied().collect())?;
        let used: HashSet<_> = frame.meshes.iter().map(|m| m.geometry).collect();
        let bytes = self
            .geometries
            .iter()
            .filter(|(id, _)| used.contains(id))
            .map(|(_, g)| g.bytes)
            .sum::<usize>()
            + frame
                .geometries
                .iter()
                .map(|g| g.positions.len() * 24 + g.indices.len() * 4)
                .sum::<usize>();
        if bytes > 64 * 1024 * 1024 {
            return Err("scene exceeds the 64 MiB geometry budget".into());
        }
        self.geometries.retain(|id, _| used.contains(id));
        for geometry in &frame.geometries {
            let vertices: Vec<Vertex> = geometry
                .positions
                .iter()
                .zip(&geometry.normals)
                .map(|(&position, &normal)| Vertex { position, normal })
                .collect();
            let vertices = self
                .device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: None,
                    contents: bytemuck::cast_slice(&vertices),
                    usage: wgpu::BufferUsages::VERTEX,
                });
            let indices = self
                .device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: None,
                    contents: bytemuck::cast_slice(&geometry.indices),
                    usage: wgpu::BufferUsages::INDEX,
                });
            self.geometries.insert(
                geometry.id,
                GpuGeometry {
                    vertices,
                    indices,
                    count: geometry.indices.len() as u32,
                    bytes: geometry.positions.len() * 24 + geometry.indices.len() * 4,
                },
            );
        }
        self.resize(width, height);
        let target = self.targets.as_ref().unwrap();
        let vp = Mat4::from_cols_array(&frame.view_projection);
        let bindings: Vec<_> = frame
            .meshes
            .iter()
            .map(|mesh| {
                let model = Mat4::from_cols_array(&mesh.model);
                let uniforms = Uniforms {
                    mvp: (vp * model).to_cols_array(),
                    normal_matrix: model.inverse().transpose().to_cols_array(),
                    color_unlit: [
                        mesh.color[0],
                        mesh.color[1],
                        mesh.color[2],
                        if mesh.unlit { 1.0 } else { 0.0 },
                    ],
                    light_ambient: [
                        frame.light_direction[0],
                        frame.light_direction[1],
                        frame.light_direction[2],
                        frame.ambient,
                    ],
                };
                let buffer = self
                    .device
                    .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: None,
                        contents: bytemuck::bytes_of(&uniforms),
                        usage: wgpu::BufferUsages::UNIFORM,
                    });
                self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: None,
                    layout: &self.layout,
                    entries: &[wgpu::BindGroupEntry {
                        binding: 0,
                        resource: buffer.as_entire_binding(),
                    }],
                })
            })
            .collect();
        let mut encoder = self.device.create_command_encoder(&Default::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("native frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &target.color_view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: frame.background[0],
                            g: frame.background[1],
                            b: frame.background[2],
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: &target.depth_view,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: wgpu::StoreOp::Discard,
                    }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            pass.set_pipeline(&self.pipeline);
            for (mesh, binding) in frame.meshes.iter().zip(&bindings) {
                let geometry = &self.geometries[&mesh.geometry];
                pass.set_bind_group(0, binding, &[]);
                pass.set_vertex_buffer(0, geometry.vertices.slice(..));
                pass.set_index_buffer(geometry.indices.slice(..), wgpu::IndexFormat::Uint32);
                pass.draw_indexed(0..geometry.count, 0, 0..1);
            }
        }
        encoder.copy_texture_to_buffer(
            target.color.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &target.readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(target.stride),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit([encoder.finish()]);
        let slice = target.readback.slice(..);
        let (sender, receiver) = mpsc::sync_channel(1);
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.device
            .poll(wgpu::PollType::wait_indefinitely())
            .map_err(|e| format!("GPU poll failed: {e}"))?;
        receiver
            .recv()
            .map_err(|e| e.to_string())?
            .map_err(|e| format!("readback failed: {e}"))?;
        let mapped = slice.get_mapped_range().map_err(|e| e.to_string())?;
        let mut pixels = Vec::with_capacity(len);
        for row in mapped.chunks_exact(target.stride as usize) {
            pixels.extend_from_slice(&row[..width as usize * 4]);
        }
        drop(mapped);
        target.readback.unmap();
        Ok(pixels)
    }
}
