use super::*;
use crate::scene::RenderSettings;

pub const HDR: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const TARGET_BUDGET: u64 = 128 * 1024 * 1024;

pub fn layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    let texture = |binding, sample_type| wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type,
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    };
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("screen effect input"),
        entries: &[
            texture(0, wgpu::TextureSampleType::Float { filterable: true }),
            texture(1, wgpu::TextureSampleType::Depth),
            texture(2, wgpu::TextureSampleType::Float { filterable: true }),
            wgpu::BindGroupLayoutEntry {
                binding: 3,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(96),
                },
                count: None,
            },
        ],
    })
}
pub fn pipeline(
    device: &wgpu::Device,
    shader: &wgpu::ShaderModule,
    layout: &wgpu::PipelineLayout,
    vertex: &str,
    fragment: &str,
    format: wgpu::TextureFormat,
) -> wgpu::RenderPipeline {
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("screen effect"),
        layout: Some(layout),
        vertex: wgpu::VertexState {
            module: shader,
            entry_point: Some(vertex),
            compilation_options: Default::default(),
            buffers: &[],
        },
        fragment: Some(wgpu::FragmentState {
            module: shader,
            entry_point: Some(fragment),
            compilation_options: Default::default(),
            targets: &[Some(wgpu::ColorTargetState {
                format,
                blend: None,
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: Default::default(),
        depth_stencil: None,
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    })
}
struct Image {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
}
impl Image {
    fn new(device: &wgpu::Device, width: u32, height: u32, format: wgpu::TextureFormat) -> Self {
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("view HDR/history"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_SRC
                | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        Self {
            view: texture.create_view(&Default::default()),
            texture,
        }
    }
}
struct View {
    width: u32,
    height: u32,
    images: [Image; 3],
    history: Image,
    depth: Image,
    settings: RenderSettings,
    camera: [f32; 16],
    valid: bool,
}
impl View {
    fn bytes(&self) -> u64 {
        self.width as u64 * self.height as u64 * 36
    }
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ScreenUniforms {
    inverse: [f32; 16],
    viewport: [f32; 4],
    output: [f32; 4],
}

#[derive(Default)]
pub(super) struct Effects {
    views: HashMap<u64, View>,
    outputs: HashMap<wgpu::TextureFormat, wgpu::RenderPipeline>,
}
impl Effects {
    pub fn remove(&mut self, id: u64) {
        self.views.remove(&id);
    }
    pub fn bytes(&self) -> u64 {
        self.views.values().map(View::bytes).sum()
    }
    fn prepare(
        &mut self,
        device: &wgpu::Device,
        frame: &Frame,
        size: [u32; 2],
        format: wgpu::TextureFormat,
    ) -> Result<(), String> {
        let id = frame.binary.as_ref().map_or(0, |v| v.view);
        if !frame.settings.enabled {
            self.remove(id);
            return Ok(());
        }
        let [width, height] = size;
        let requested = width as u64 * height as u64 * 36;
        let other: u64 = self
            .views
            .iter()
            .filter(|(key, _)| **key != id)
            .map(|(_, v)| v.bytes())
            .sum();
        if requested + other > TARGET_BUDGET {
            return Err("HDR targets exceed the 128 MiB device target budget".into());
        }
        if !Mat4::from_cols_array(&frame.view_projection)
            .inverse()
            .is_finite()
        {
            return Err("Screen effects require an invertible camera projection".into());
        }
        self.outputs.entry(format).or_insert_with(|| {
            let shader = device.create_shader_module(wgpu::include_wgsl!("output.wgsl"));
            let bind_layout = layout(device);
            let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("output conversion"),
                bind_group_layouts: &[Some(&bind_layout)],
                ..Default::default()
            });
            pipeline(
                device,
                &shader,
                &pipeline_layout,
                "vertex",
                "fragment",
                format,
            )
        });
        if self
            .views
            .get(&id)
            .is_none_or(|v| v.width != width || v.height != height)
        {
            self.views.insert(
                id,
                View {
                    width,
                    height,
                    images: std::array::from_fn(|_| Image::new(device, width, height, HDR)),
                    history: Image::new(device, width, height, HDR),
                    depth: Image::new(device, width, height, wgpu::TextureFormat::Depth32Float),
                    settings: frame.settings.clone(),
                    camera: frame.view_projection,
                    valid: false,
                },
            );
        }
        let view = self.views.get_mut(&id).unwrap();
        if view.settings != frame.settings || view.camera != frame.view_projection {
            view.valid = false;
        }
        view.settings = frame.settings.clone();
        view.camera = frame.view_projection;
        Ok(())
    }
}

impl Renderer {
    pub(super) fn prepare_output(
        &mut self,
        frame: &Frame,
        size: [u32; 2],
        format: wgpu::TextureFormat,
    ) -> Result<(), String> {
        frame.settings.validate()?;
        for key in &frame.settings.effects {
            if self
                .graphs
                .materials
                .resolve(*key)
                .map_err(|e| e.to_string())?
                .screen_pipeline
                .is_none()
            {
                return Err("Screen effects require a fullscreen shader".into());
            }
        }
        let state = self.state.as_mut().unwrap();
        state.effects.prepare(&state.device, frame, size, format)
    }
    pub(super) fn encode_frame(
        &self,
        frame: &Frame,
        output: &wgpu::TextureView,
        depth: &wgpu::TextureView,
        format: wgpu::TextureFormat,
        size: [u32; 2],
    ) -> wgpu::CommandEncoder {
        if !frame.settings.enabled {
            return self.encode_scene(frame, output, depth, format, size);
        }
        let id = frame.binary.as_ref().map_or(0, |v| v.view);
        let view = &self.effects.views[&id];
        let mut encoder =
            self.encode_scene(frame, &view.images[0].view, &view.depth.view, HDR, size);
        let uniforms = ScreenUniforms {
            inverse: Mat4::from_cols_array(&frame.view_projection)
                .inverse()
                .to_cols_array(),
            viewport: [
                size[0] as f32,
                size[1] as f32,
                if view.valid { 1. } else { 0. },
                frame.settings.exposure,
            ],
            output: [
                frame.settings.tone_mapping as f32,
                if format.is_srgb() { 1. } else { 0. },
                0.,
                0.,
            ],
        };
        let buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("screen uniforms"),
                contents: bytemuck::bytes_of(&uniforms),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let bind = |pipeline: &wgpu::RenderPipeline, input: &wgpu::TextureView| {
            self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("screen inputs"),
                layout: &pipeline.get_bind_group_layout(0),
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(input),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(&view.depth.view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: wgpu::BindingResource::TextureView(&view.history.view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 3,
                        resource: buffer.as_entire_binding(),
                    },
                ],
            })
        };
        let mut current = 0;
        for key in &frame.settings.effects {
            let material = self
                .graphs
                .materials
                .resolve(*key)
                .expect("validated screen shader");
            let pipeline = material.screen_pipeline.as_ref().unwrap();
            let next = if current == 1 { 2 } else { 1 };
            let group = bind(pipeline, &view.images[current].view);
            draw(
                &mut encoder,
                &view.images[next].view,
                pipeline,
                &group,
                &material.groups,
            );
            current = next;
        }
        let pipeline = &self.effects.outputs[&format];
        let group = bind(pipeline, &view.images[current].view);
        draw(&mut encoder, output, pipeline, &group, &[]);
        encoder.copy_texture_to_texture(
            view.images[current].texture.as_image_copy(),
            view.history.texture.as_image_copy(),
            wgpu::Extent3d {
                width: size[0],
                height: size[1],
                depth_or_array_layers: 1,
            },
        );
        encoder
    }
    pub(super) fn accept_history(&mut self, frame: &Frame) {
        let id = frame.binary.as_ref().map_or(0, |v| v.view);
        if let Some(view) = self.effects.views.get_mut(&id) {
            view.valid = true;
        }
    }
}
fn draw(
    encoder: &mut wgpu::CommandEncoder,
    target: &wgpu::TextureView,
    pipeline: &wgpu::RenderPipeline,
    group: &wgpu::BindGroup,
    user: &[wgpu::BindGroup],
) {
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("screen effect"),
        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
            view: target,
            resolve_target: None,
            depth_slice: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                store: wgpu::StoreOp::Store,
            },
        })],
        ..Default::default()
    });
    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, group, &[]);
    for (index, group) in user.iter().enumerate() {
        pass.set_bind_group(index as u32 + 1, group, &[]);
    }
    pass.draw(0..3, 0..1);
}
