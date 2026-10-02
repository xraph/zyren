use super::*;
use crate::scene::RenderSettings;

#[path = "bloom.rs"]
mod bloom;

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
                    min_binding_size: wgpu::BufferSize::new(112),
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
    multisample: Option<multisample::Multisample>,
    bloom: Option<bloom::Targets>,
    settings: RenderSettings,
    camera: [f32; 16],
    valid: bool,
}
impl View {
    fn bytes(&self) -> u64 {
        self.width as u64 * self.height as u64 * if self.multisample.is_some() { 84 } else { 36 }
            + self.bloom.as_ref().map_or(0, bloom::Targets::bytes)
    }
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ScreenUniforms {
    inverse: [f32; 16],
    viewport: [f32; 4],
    output: [f32; 4],
    depth: [f32; 4],
}

#[derive(Default)]
pub(super) struct Effects {
    views: HashMap<u64, View>,
    outputs: HashMap<wgpu::TextureFormat, wgpu::RenderPipeline>,
    depth_resolve: [Option<wgpu::RenderPipeline>; 2],
    bloom: Option<bloom::Pipelines>,
    display: Option<wgpu::RenderPipeline>,
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
        let requested = width as u64
            * height as u64
            * if frame.settings.sample_count == 4 {
                84
            } else {
                36
            };
        let requested =
            requested + bloom::Targets::byte_length(size, frame.settings.bloom.as_ref());
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
        let resolve = &mut self.depth_resolve[frame.settings.depth_strategy as usize];
        if frame.settings.sample_count == 4 && resolve.is_none() {
            *resolve = Some(multisample::pipeline(
                device,
                frame.settings.reversed_depth(),
            ));
        }
        if bloom::Targets::byte_length(size, frame.settings.bloom.as_ref()) > 0
            && self.bloom.is_none()
        {
            self.bloom = Some(bloom::Pipelines::new(device));
        }
        if self.display.is_none() {
            let shader = device.create_shader_module(wgpu::include_wgsl!("output.wgsl"));
            let bindings = layout(device);
            let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("FXAA display input"),
                bind_group_layouts: &[Some(&bindings)],
                ..Default::default()
            });
            self.display = Some(pipeline(device, &shader, &layout, "vertex", "display", HDR));
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
        if self.views.get(&id).is_none_or(|v| {
            v.width != width
                || v.height != height
                || v.settings.sample_count != frame.settings.sample_count
                || v.bloom.as_ref().map_or(0, bloom::Targets::bytes)
                    != bloom::Targets::byte_length(size, frame.settings.bloom.as_ref())
        }) {
            let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
            let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
            let candidate = View {
                width,
                height,
                images: std::array::from_fn(|_| Image::new(device, width, height, HDR)),
                history: Image::new(device, width, height, HDR),
                depth: Image::new(device, width, height, wgpu::TextureFormat::Depth32Float),
                multisample: (frame.settings.sample_count == 4)
                    .then(|| multisample::Multisample::new(device, size)),
                bloom: bloom::Targets::new(device, size, frame.settings.bloom.as_ref()),
                settings: frame.settings.clone(),
                camera: frame.view_projection,
                valid: false,
            };
            let mut failure = None;
            for scope in [memory, validation] {
                if let Some(error) = pollster::block_on(scope.pop()) {
                    failure = Some(error.to_string());
                }
            }
            if let Some(error) = failure {
                return Err(error);
            }
            self.views.insert(id, candidate);
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
        if frame.settings.sample_count == 4 && !self.supports_msaa4 {
            return Err("Four-sample HDR/depth antialiasing is unsupported on this device".into());
        }
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
        state.effects.prepare(&state.device, frame, size, format)?;
        state.outlines.prepare(&state.device, frame, size, format)
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
            let mut encoder = self.encode_scene(frame, output, depth, format, size, None);
            self.outlines
                .encode(&self.device, &mut encoder, frame, output, format);
            return encoder;
        }
        let id = frame.binary.as_ref().map_or(0, |v| v.view);
        let view = &self.effects.views[&id];
        let mut encoder = if let Some(msaa) = &view.multisample {
            let mut encoder = self.encode_scene(
                frame,
                &msaa.color,
                &msaa.depth,
                HDR,
                size,
                Some(&view.images[0].view),
            );
            multisample::resolve(
                &self.device,
                &mut encoder,
                self.effects.depth_resolve[frame.settings.depth_strategy as usize]
                    .as_ref()
                    .expect("depth resolve pipeline"),
                &msaa.depth,
                &view.depth.view,
                frame.settings.depth_clear(),
            );
            encoder
        } else {
            self.encode_scene(
                frame,
                &view.images[0].view,
                &view.depth.view,
                HDR,
                size,
                None,
            )
        };
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
                frame.settings.spatial_antialiasing as f32,
                0.,
            ],
            depth: [frame.settings.depth_strategy as f32, 0., 0., 0.],
        };
        let buffer = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("screen uniforms"),
                contents: bytemuck::bytes_of(&uniforms),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let bind =
            |pipeline: &wgpu::RenderPipeline, input: &wgpu::TextureView, buffer: &wgpu::Buffer| {
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
            if material.screen_stage != 0 {
                continue;
            }
            let pipeline = material.screen_pipeline.as_ref().unwrap();
            let next = if current == 1 { 2 } else { 1 };
            let group = bind(pipeline, &view.images[current].view, &buffer);
            draw(
                &mut encoder,
                &view.images[next].view,
                pipeline,
                &group,
                &material.groups,
            );
            current = next;
        }
        // History is the custom-effect HDR result, before bloom and output AA.
        // Reusing a display halo as next frame's scene input would add it twice.
        encoder.copy_texture_to_texture(
            view.images[current].texture.as_image_copy(),
            view.history.texture.as_image_copy(),
            wgpu::Extent3d {
                width: size[0],
                height: size[1],
                depth_or_array_layers: 1,
            },
        );
        if let Some(targets) = &view.bloom {
            let next = if current == 1 { 2 } else { 1 };
            self.effects.bloom.as_ref().unwrap().encode(
                &self.device,
                &mut encoder,
                targets,
                frame.settings.bloom.as_ref().unwrap(),
                &view.images[current].view,
                &view.images[next].view,
            );
            current = next;
        }
        let has_display = frame
            .settings
            .effects
            .iter()
            .any(|key| self.graphs.materials.resolve(*key).unwrap().screen_stage == 1);
        let output_buffer = if frame.settings.spatial_antialiasing != 0 || has_display {
            // Reuse an HDR ping-pong image for encoded display colors. FXAA can
            // sample it many times without repeating exposure/tone/transfer math.
            let next = if current == 1 { 2 } else { 1 };
            let pipeline = self.effects.display.as_ref().unwrap();
            let group = bind(pipeline, &view.images[current].view, &buffer);
            draw(&mut encoder, &view.images[next].view, pipeline, &group, &[]);
            current = next;
            let mut encoded = uniforms;
            encoded.output[3] = 1.;
            self.device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("FXAA output uniforms"),
                    contents: bytemuck::bytes_of(&encoded),
                    usage: wgpu::BufferUsages::UNIFORM,
                })
        } else {
            buffer
        };
        for key in &frame.settings.effects {
            let material = self.graphs.materials.resolve(*key).unwrap();
            if material.screen_stage != 1 {
                continue;
            }
            let pipeline = material.screen_pipeline.as_ref().unwrap();
            let next = if current == 1 { 2 } else { 1 };
            let group = bind(pipeline, &view.images[current].view, &output_buffer);
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
        let group = bind(pipeline, &view.images[current].view, &output_buffer);
        draw(&mut encoder, output, pipeline, &group, &[]);
        self.outlines
            .encode(&self.device, &mut encoder, frame, output, format);
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
