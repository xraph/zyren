use super::*;

pub(super) const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba8Unorm;
const BUDGET: u64 = 64 * 1024 * 1024;

pub(super) struct View {
    size: [u32; 2],
    samples: u32,
    mask: wgpu::TextureView,
    format: wgpu::TextureFormat,
    background: Option<wgpu::TextureView>,
    multisample: Option<wgpu::TextureView>,
}
impl View {
    fn bytes(&self) -> u64 {
        bytes(self.size, self.samples, self.background.is_some())
    }
    pub fn attachment(&self) -> &wgpu::TextureView {
        self.multisample.as_ref().unwrap_or(&self.mask)
    }
    pub fn resolve(&self) -> Option<&wgpu::TextureView> {
        self.multisample.as_ref().map(|_| &self.mask)
    }
}
fn bytes(size: [u32; 2], samples: u32, composite: bool) -> u64 {
    size[0] as u64
        * size[1] as u64
        * (if samples == 4 { 20 } else { 4 } + if composite { 4 } else { 0 })
}
fn id(frame: &Frame) -> u64 {
    frame.binary.as_ref().map_or(0, |packet| packet.view)
}

#[derive(Default)]
pub(super) struct Outlines {
    views: HashMap<u64, View>,
    pipelines: HashMap<(wgpu::TextureFormat, bool), wgpu::RenderPipeline>,
}
impl Outlines {
    pub fn remove(&mut self, id: u64) {
        self.views.remove(&id);
    }
    pub fn bytes(&self) -> u64 {
        self.views.values().map(View::bytes).sum()
    }
    pub fn view(&self, frame: &Frame) -> Option<&View> {
        self.views.get(&id(frame))
    }
    pub fn color_target(&self, frame: &Frame) -> Option<&wgpu::TextureView> {
        self.view(frame).and_then(|view| view.background.as_ref())
    }
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        frame: &Frame,
        size: [u32; 2],
        format: wgpu::TextureFormat,
    ) -> Result<(), String> {
        let id = id(frame);
        if frame.settings.outline.is_none() || !frame.meshes.iter().any(|mesh| mesh.outlined) {
            self.remove(id);
            return Ok(());
        }
        let samples = frame.sample_count();
        let composite =
            frame.background_alpha < 1. || frame.settings.enabled || frame.graph.is_some();
        let key = (format, composite);
        let other = self.bytes() - self.views.get(&id).map_or(0, View::bytes);
        if bytes(size, samples, composite) + other > BUDGET {
            return Err("Outline targets exceed the 64 MiB device target budget".into());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let pipeline = (!self.pipelines.contains_key(&key)).then(|| {
            let shader = device.create_shader_module(wgpu::include_wgsl!("outlines.wgsl"));
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("selection outline overlay"),
                layout: None,
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some("vertex"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some("fragment"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend: (!composite).then_some(wgpu::BlendState::ALPHA_BLENDING),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: Default::default(),
                depth_stencil: None,
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            })
        });
        let view = self
            .views
            .get(&id)
            .is_none_or(|v| {
                v.size != size
                    || v.samples != samples
                    || v.format != format
                    || v.background.is_some() != composite
            })
            .then(|| {
                let make = |sample_count, format| {
                    device
                        .create_texture(&wgpu::TextureDescriptor {
                            label: Some("selection coverage"),
                            size: wgpu::Extent3d {
                                width: size[0],
                                height: size[1],
                                depth_or_array_layers: 1,
                            },
                            mip_level_count: 1,
                            sample_count,
                            dimension: wgpu::TextureDimension::D2,
                            format,
                            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                                | wgpu::TextureUsages::TEXTURE_BINDING,
                            view_formats: &[],
                        })
                        .create_view(&Default::default())
                };
                View {
                    size,
                    samples,
                    format,
                    background: composite.then(|| make(1, format)),
                    mask: make(1, FORMAT),
                    multisample: (samples == 4).then(|| make(4, FORMAT)),
                }
            });
        let mut failure = None;
        for scope in [memory, validation] {
            if let Some(error) = pollster::block_on(scope.pop()) {
                failure = Some(error.to_string());
            }
        }
        if let Some(error) = failure {
            return Err(error);
        }
        if let Some(view) = view {
            self.views.insert(id, view);
        }
        if let Some(pipeline) = pipeline {
            self.pipelines.insert(key, pipeline);
        }
        Ok(())
    }

    pub fn encode(
        &self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        frame: &Frame,
        output: &wgpu::TextureView,
        format: wgpu::TextureFormat,
        associated: bool,
    ) {
        let Some(view) = self.view(frame) else {
            return;
        };
        let style = frame.settings.outline.as_ref().expect("prepared outline");
        let composite = view.background.is_some();
        let pipeline = &self.pipelines[&(format, composite)];
        let values = [
            style.color[0],
            style.color[1],
            style.color[2],
            style.color[3],
            style.width as f32,
            if format.is_srgb() { 1. } else { 0. },
            if composite { 1. } else { 0. },
            if associated { 1. } else { 0. },
        ];
        let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("outline style"),
            contents: bytemuck::cast_slice(&values),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("outline coverage"),
            layout: &pipeline.get_bind_group_layout(0),
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view.mask),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::TextureView(
                        view.background.as_ref().unwrap_or(&view.mask),
                    ),
                },
            ],
        });
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("selection outlines"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: output,
                resolve_target: None,
                depth_slice: None,
                ops: wgpu::Operations {
                    load: if composite {
                        wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT)
                    } else {
                        wgpu::LoadOp::Load
                    },
                    store: wgpu::StoreOp::Store,
                },
            })],
            ..Default::default()
        });
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, &group, &[]);
        pass.draw(0..3, 0..1);
    }
}
