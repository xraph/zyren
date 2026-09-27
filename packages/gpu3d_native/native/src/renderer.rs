use std::{
    collections::{HashMap, HashSet},
    sync::mpsc,
    time::Duration,
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

#[derive(Clone, Copy, Debug, Default)]
pub struct RenderCounters {
    pub submitted_frames: u64,
    pub readback_bytes: u64,
}
#[cfg(target_vendor = "apple")]
struct DepthTarget {
    width: u32,
    height: u32,
    _texture: wgpu::Texture,
    view: wgpu::TextureView,
}

struct Submission {
    index: wgpu::SubmissionIndex,
    #[cfg(target_vendor = "apple")]
    metal: Option<crate::interop::metal::MetalCompletion>,
}

pub struct Renderer {
    state: Option<Box<RendererState>>,
}

// Fields remain private; dereferencing keeps the renderer implementation local
// while allowing its complete GPU ownership to move during retirement.
#[doc(hidden)]
pub struct RendererState {
    pub(crate) device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    #[cfg(target_vendor = "apple")]
    surface_pipeline: wgpu::RenderPipeline,
    #[cfg(target_vendor = "apple")]
    surface_depth: Option<DepthTarget>,
    #[cfg(target_vendor = "apple")]
    failed_surface: Option<wgpu::Texture>,
    #[cfg(target_vendor = "apple")]
    pub(crate) drawable_owner: Option<crate::interop::metal::DrawableOwner>,
    pub(crate) failure: Option<String>,
    counters: RenderCounters,
    layout: wgpu::BindGroupLayout,
    geometries: HashMap<u32, GpuGeometry>,
    targets: Option<Targets>,
    pub adapter_name: String,
    pub backend: wgpu::Backend,
    _permit: crate::retirement::DevicePermit,
}
impl std::ops::Deref for Renderer {
    type Target = RendererState;
    fn deref(&self) -> &Self::Target {
        self.state.as_deref().expect("renderer owns its state")
    }
}
impl std::ops::DerefMut for Renderer {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.state.as_deref_mut().expect("renderer owns its state")
    }
}
impl Drop for Renderer {
    fn drop(&mut self) {
        if let Some(state) = self.state.take() {
            if state.failure.is_some() {
                crate::retirement::retire(state);
            } else {
                drop(state);
            }
        }
    }
}

impl Renderer {
    pub async fn new() -> Result<Self, String> {
        let permit = crate::retirement::reserve_device()?;
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
        let create_pipeline = |format| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
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
                        format,
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
            })
        };
        let pipeline = create_pipeline(wgpu::TextureFormat::Rgba8UnormSrgb);
        #[cfg(target_vendor = "apple")]
        let surface_pipeline = create_pipeline(wgpu::TextureFormat::Bgra8UnormSrgb);
        Ok(Self {
            state: Some(Box::new(RendererState {
                device,
                queue,
                pipeline,
                #[cfg(target_vendor = "apple")]
                surface_pipeline,
                #[cfg(target_vendor = "apple")]
                surface_depth: None,
                #[cfg(target_vendor = "apple")]
                failed_surface: None,
                #[cfg(target_vendor = "apple")]
                drawable_owner: None,
                failure: None,
                counters: RenderCounters::default(),
                layout,
                geometries: HashMap::new(),
                targets: None,
                adapter_name: info.name,
                backend: info.backend,
                _permit: permit,
            })),
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

    pub fn counters(&self) -> RenderCounters {
        self.counters
    }

    fn prepare_scene(&mut self, frame: &Frame) -> Result<(), String> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
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
        Ok(())
    }

    fn encode_scene(
        &self,
        frame: &Frame,
        color_view: &wgpu::TextureView,
        depth_view: &wgpu::TextureView,
        pipeline: &wgpu::RenderPipeline,
    ) -> wgpu::CommandEncoder {
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
                    view: color_view,
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
                    view: depth_view,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: wgpu::StoreOp::Discard,
                    }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            pass.set_pipeline(pipeline);
            for (mesh, binding) in frame.meshes.iter().zip(&bindings) {
                let geometry = &self.geometries[&mesh.geometry];
                pass.set_bind_group(0, binding, &[]);
                pass.set_vertex_buffer(0, geometry.vertices.slice(..));
                pass.set_index_buffer(geometry.indices.slice(..), wgpu::IndexFormat::Uint32);
                pass.draw_indexed(0..geometry.count, 0, 0..1);
            }
        }
        encoder
    }

    fn submit(&mut self, encoder: wgpu::CommandEncoder) -> Result<Submission, String> {
        let index = self.queue.submit([encoder.finish()]);
        self.counters.submitted_frames += 1;
        #[cfg(target_vendor = "apple")]
        let metal = if self.backend == wgpu::Backend::Metal {
            match crate::interop::metal::MetalCompletion::capture(&self.queue) {
                Ok(completion) => Some(completion),
                Err(error) => {
                    self.failure = Some(error.clone());
                    return Err(error);
                }
            }
        } else {
            None
        };
        Ok(Submission {
            index,
            #[cfg(target_vendor = "apple")]
            metal,
        })
    }

    fn wait_for_submission(&mut self, submission: Submission) -> Result<(), String> {
        let result = self
            .device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(submission.index),
                timeout: Some(Duration::from_secs(2)),
            })
            .map(|_| ())
            .map_err(|error| error.to_string());
        #[cfg(target_vendor = "apple")]
        let result = result.and_then(|()| match submission.metal {
            Some(completion) => completion.check(),
            None => Ok(()),
        });
        result.map_err(|error| {
            let message = format!("GPU completion failed; recreate this renderer: {error}");
            self.failure = Some(message.clone());
            message
        })
    }

    #[cfg(target_vendor = "apple")]
    pub(crate) fn render_to_surface(
        &mut self,
        frame: &Frame,
        texture: wgpu::Texture,
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        pixel_len(width, height)?;
        self.prepare_scene(frame)?;
        if self
            .surface_depth
            .as_ref()
            .is_none_or(|target| target.width != width || target.height != height)
        {
            let depth = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("shared frame depth"),
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            self.surface_depth = Some(DepthTarget {
                width,
                height,
                view: depth.create_view(&Default::default()),
                _texture: depth,
            });
        }
        let encoder = self.encode_scene(
            frame,
            &texture.create_view(&Default::default()),
            &self.surface_depth.as_ref().unwrap().view,
            &self.surface_pipeline,
        );
        let result = self
            .submit(encoder)
            .and_then(|submission| self.wait_for_submission(submission));
        if let Err(error) = result {
            // Stop future submissions and keep the imported resource owned.
            self.failed_surface = Some(texture);
            return Err(error);
        }
        Ok(())
    }

    pub fn render(&mut self, frame: &Frame, width: u32, height: u32) -> Result<Vec<u8>, String> {
        let len = pixel_len(width, height)?;
        self.prepare_scene(frame)?;
        self.resize(width, height);
        let target = self.targets.as_ref().unwrap();
        let mut encoder = self.encode_scene(
            frame,
            &target.color_view,
            &target.depth_view,
            &self.pipeline,
        );
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
        let readback = target.readback.clone();
        let stride = target.stride;
        let submission = self.submit(encoder)?;
        let slice = readback.slice(..);
        let (sender, receiver) = mpsc::sync_channel(1);
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.wait_for_submission(submission)?;
        let mapped_result = receiver
            .recv_timeout(Duration::from_secs(1))
            .map_err(|error| format!("readback callback failed: {error}"))
            .and_then(|result| result.map_err(|error| format!("readback failed: {error}")));
        if let Err(error) = mapped_result {
            self.failure = Some(error.clone());
            return Err(error);
        }
        let mapped = slice.get_mapped_range().map_err(|e| e.to_string())?;
        let mut pixels = Vec::with_capacity(len);
        for row in mapped.chunks_exact(stride as usize) {
            pixels.extend_from_slice(&row[..width as usize * 4]);
        }
        drop(mapped);
        readback.unmap();
        self.counters.readback_bytes += pixels.len() as u64;
        Ok(pixels)
    }
}

#[cfg(all(test, target_vendor = "apple"))]
mod metal_timeout_tests {
    use super::*;
    use objc2::runtime::ProtocolObject;
    use objc2_metal::{
        MTLCommandBuffer, MTLCommandQueue, MTLDevice, MTLPixelFormat, MTLSharedEvent,
        MTLStorageMode, MTLTextureDescriptor, MTLTextureUsage,
    };

    #[test]
    #[ignore = "requires a native Metal device; blocks a private queue for three seconds"]
    fn gpu_timeout_retains_imported_texture_and_stops_new_submissions() {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let device = renderer.metal_device().unwrap();
        let descriptor = MTLTextureDescriptor::new();
        unsafe {
            descriptor.setWidth(16);
            descriptor.setHeight(16);
        }
        descriptor.setPixelFormat(MTLPixelFormat::BGRA8Unorm_sRGB);
        descriptor.setUsage(MTLTextureUsage::RenderTarget);
        descriptor.setStorageMode(MTLStorageMode::Shared);
        let texture = device.newTextureWithDescriptor(&descriptor).unwrap();
        let gate = device.newSharedEvent().unwrap();
        {
            // Exclusive renderer access: no wgpu submissions race this native wait.
            let queue = unsafe { renderer.queue.as_hal::<wgpu::hal::api::Metal>() }.unwrap();
            let blocker = queue.as_raw().commandBuffer().unwrap();
            blocker.encodeWaitForEvent_value(ProtocolObject::from_ref(&*gate), 1);
            blocker.commit();
        }
        let signal = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(3));
            gate.setSignaledValue(1);
        });
        let frame: Frame = serde_json::from_value(serde_json::json!({
            "version": 1, "view_projection": glam::Mat4::IDENTITY.to_cols_array(),
            "background": [0,0,0], "light_direction": [0,0,1], "ambient": 0.2,
            "geometries": [], "meshes": []
        }))
        .unwrap();
        let result = unsafe { renderer.render_to_metal(&frame, texture) };
        assert!(
            result.is_err(),
            "GPU wait must expire before the timer releases it"
        );
        assert!(
            renderer.failed_surface.is_some(),
            "active imported storage stays owned"
        );
        assert!(renderer.render(&frame, 16, 16).is_err());
        assert_eq!(renderer.counters().submitted_frames, 1);
        let closing = std::time::Instant::now();
        drop(renderer);
        assert!(
            closing.elapsed() < Duration::from_millis(250),
            "disposal must not wait for the blocked GPU queue"
        );
        assert_eq!(crate::fg_retiring_renderer_count(), 1);
        signal.join().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while crate::fg_retiring_renderer_count() != 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(crate::fg_retiring_renderer_count(), 0);
    }
}
