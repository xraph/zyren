use super::{HDR, Image, draw, pipeline};
use crate::scene::BloomSettings;
use wgpu::util::DeviceExt;

struct Level {
    down: Image,
    up: Image,
}
pub(super) struct Targets {
    levels: Vec<Level>,
    bytes: u64,
}
fn sizes(mut size: [u32; 2], levels: u32) -> Vec<[u32; 2]> {
    let mut result = Vec::new();
    for _ in 0..levels {
        size = size.map(|v| v.div_ceil(2).max(1));
        result.push(size);
        if size == [1, 1] {
            break;
        }
    }
    result
}
impl Targets {
    pub fn byte_length(size: [u32; 2], settings: Option<&BloomSettings>) -> u64 {
        settings.filter(|s| s.intensity > 0.).map_or(0, |s| {
            sizes(size, s.levels)
                .iter()
                .map(|s| s[0] as u64 * s[1] as u64 * 16)
                .sum()
        })
    }
    pub fn new(
        device: &wgpu::Device,
        size: [u32; 2],
        settings: Option<&BloomSettings>,
    ) -> Option<Self> {
        let settings = settings.filter(|s| s.intensity > 0.)?;
        Some(Self {
            levels: sizes(size, settings.levels)
                .iter()
                .map(|s| Level {
                    down: Image::new(device, s[0], s[1], HDR),
                    up: Image::new(device, s[0], s[1], HDR),
                })
                .collect(),
            bytes: Self::byte_length(size, Some(settings)),
        })
    }
    pub fn bytes(&self) -> u64 {
        self.bytes
    }
}
pub(super) struct Pipelines {
    down: wgpu::RenderPipeline,
    up: wgpu::RenderPipeline,
    combine: wgpu::RenderPipeline,
}
impl Pipelines {
    pub fn new(device: &wgpu::Device) -> Self {
        let texture = |binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        };
        let bindings = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("bloom inputs"),
            entries: &[
                texture(0),
                texture(1),
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(32),
                    },
                    count: None,
                },
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("bloom pyramid"),
            bind_group_layouts: &[Some(&bindings)],
            ..Default::default()
        });
        let shader = device.create_shader_module(wgpu::include_wgsl!("bloom.wgsl"));
        Self {
            down: pipeline(device, &shader, &layout, "vertex", "down", HDR),
            up: pipeline(device, &shader, &layout, "vertex", "up", HDR),
            combine: pipeline(device, &shader, &layout, "vertex", "combine", HDR),
        }
    }
    pub fn encode(
        &self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        targets: &Targets,
        settings: &BloomSettings,
        source: &wgpu::TextureView,
        output: &wgpu::TextureView,
    ) {
        let mut pass = |pipeline: &wgpu::RenderPipeline,
                        input: &wgpu::TextureView,
                        lower: &wgpu::TextureView,
                        target: &wgpu::TextureView,
                        extract: bool| {
            let values = [
                settings.threshold,
                settings.soft_knee,
                settings.scatter,
                settings.intensity,
                if extract { 1. } else { 0. },
                0.,
                0.,
                0.,
            ];
            let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("bloom parameters"),
                contents: bytemuck::cast_slice(&values),
                usage: wgpu::BufferUsages::UNIFORM,
            });
            let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("bloom pass"),
                layout: &pipeline.get_bind_group_layout(0),
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(input),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::TextureView(lower),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: buffer.as_entire_binding(),
                    },
                ],
            });
            draw(encoder, target, pipeline, &group, &[]);
        };
        for (i, level) in targets.levels.iter().enumerate() {
            let input = if i == 0 {
                source
            } else {
                &targets.levels[i - 1].down.view
            };
            pass(&self.down, input, input, &level.down.view, i == 0);
        }
        let mut lower = &targets.levels.last().unwrap().down.view;
        for level in targets.levels.iter().rev().skip(1) {
            pass(&self.up, &level.down.view, lower, &level.up.view, false);
            lower = &level.up.view;
        }
        pass(&self.combine, source, lower, output, false);
    }
}
