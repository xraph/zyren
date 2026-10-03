use super::Renderer;
use crate::{
    render_graph::{FrameGraph, PreparedMaterial},
    scene::Frame,
};
use std::collections::HashMap;

use wgpu::util::DeviceExt;
const OUTPUT_SHADER: &str = include_str!("output.wgsl");

pub(super) struct ResizeTarget {
    pub(super) color: wgpu::Texture,
    depth: wgpu::Texture,
    pub(super) keys: [crate::resources::registry::ResourceKey; 2],
    pub(super) view: u64,
}

struct MultisampleTargets {
    color: wgpu::Texture,
    depth: wgpu::Texture,
}
impl MultisampleTargets {
    fn prepare(
        device: &wgpu::Device,
        current: &mut Option<Self>,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        samples: u32,
    ) -> Result<(), String> {
        if samples == 1 {
            *current = None;
            return Ok(());
        }
        let pixels = u64::from(size[0]) * u64::from(size[1]);
        let bytes_per_pixel = if format == wgpu::TextureFormat::Rgba16Float {
            8
        } else {
            4
        };
        if pixels * bytes_per_pixel * u64::from(samples) > crate::resources::upload::MAX_BYTES {
            return Err("Multisample color exceeds 64 MiB per attachment; reduce render scale or sample count".into());
        }
        if current.as_ref().is_some_and(|t| {
            t.color.width() == size[0]
                && t.color.height() == size[1]
                && t.color.format() == format
                && t.color.sample_count() == samples
        }) {
            return Ok(());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let texture = |label, format| {
            device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d {
                    width: size[0],
                    height: size[1],
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: samples,
                dimension: wgpu::TextureDimension::D2,
                format,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            })
        };
        let candidate = Self {
            color: texture("multisample scene color", format),
            depth: texture("multisample scene depth", wgpu::TextureFormat::Depth32Float),
        };
        let error = pollster::block_on(internal.pop())
            .or(pollster::block_on(memory.pop()))
            .or(pollster::block_on(validation.pop()));
        if let Some(error) = error {
            return Err(error.to_string());
        }
        *current = Some(candidate);
        Ok(())
    }
}
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
struct OutputTransform {
    unassociate: bool,
    premultiply: bool,
    tone_mapping: Option<u32>,
}
#[derive(Default)]
pub(super) struct Compositor {
    pipelines: HashMap<
        (wgpu::TextureFormat, OutputTransform),
        (wgpu::RenderPipeline, wgpu::BindGroupLayout),
    >,
    pub(super) accumulation: Option<wgpu::Texture>,
    hdr: Option<wgpu::Texture>,
    pub(super) resized: Option<ResizeTarget>,
    multisample: Option<MultisampleTargets>,
}
impl Compositor {
    fn prepare(
        &mut self,
        device: &wgpu::Device,
        format: wgpu::TextureFormat,
        transform: OutputTransform,
    ) -> Result<(), String> {
        if self.pipelines.contains_key(&(format, transform)) {
            return Ok(());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("frame output texture"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: false },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: wgpu::BufferSize::new(16),
                    },
                    count: None,
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("frame output"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("frame output"),
            source: wgpu::ShaderSource::Wgsl(
                OUTPUT_SHADER
                    .replace(
                        "__HDR__",
                        if transform.tone_mapping.is_some() {
                            "true"
                        } else {
                            "false"
                        },
                    )
                    .replace(
                        "__CURVE__",
                        &format!("{}u", transform.tone_mapping.unwrap_or(0)),
                    )
                    .replace(
                        "__UNASSOCIATE__",
                        if transform.unassociate {
                            "true"
                        } else {
                            "false"
                        },
                    )
                    .replace(
                        "__PREMULTIPLY__",
                        if transform.premultiply {
                            "true"
                        } else {
                            "false"
                        },
                    )
                    .replace("__SRGB__", if format.is_srgb() { "true" } else { "false" })
                    .into(),
            ),
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("frame output"),
            layout: Some(&pipeline_layout),
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
                targets: &[Some(format.into())],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        let error = pollster::block_on(internal.pop())
            .or(pollster::block_on(memory.pop()))
            .or(pollster::block_on(validation.pop()));
        if let Some(error) = error {
            return Err(error.to_string());
        }
        self.pipelines
            .insert((format, transform), (pipeline, layout));
        Ok(())
    }
    fn encode(
        &self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        source: &wgpu::Texture,
        target: &wgpu::TextureView,
        output: (wgpu::TextureFormat, OutputTransform, f32),
    ) {
        let (format, transform, exposure) = output;
        let (pipeline, layout) = &self.pipelines[&(format, transform)];
        let parameters = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("frame exposure"),
            contents: bytemuck::cast_slice(&[
                exposure,
                source.width() as f32 / target.texture().width() as f32,
                source.height() as f32 / target.texture().height() as f32,
                0.,
            ]),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let view = source.create_view(&Default::default());
        let binding = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("frame output"),
            layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: parameters.as_entire_binding(),
                },
            ],
        });
        let colors = [Some(wgpu::RenderPassColorAttachment {
            view: target,
            resolve_target: None,
            depth_slice: None,
            ops: wgpu::Operations {
                load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                store: wgpu::StoreOp::Store,
            },
        })];
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("frame output"),
            color_attachments: &colors,
            ..Default::default()
        });
        pass.set_pipeline(pipeline);
        pass.set_bind_group(0, &binding, &[]);
        pass.draw(0..3, 0..1);
    }
}
pub(super) fn scene_format(
    frame: &Frame,
    format: wgpu::TextureFormat,
    graph: Option<&FrameGraph>,
) -> Result<wgpu::TextureFormat, String> {
    if frame.settings.enabled || frame.color_pipeline.is_some() {
        if let Some(pipeline) = frame.color_pipeline {
            pipeline.validate()?;
        }
        if graph.is_some_and(|g| {
            g.scene_color.format() != wgpu::TextureFormat::Rgba16Float
                || g.output.format() != wgpu::TextureFormat::Rgba16Float
        }) {
            return Err("HDR requires RGBA16Float scene and graph output textures".into());
        }
        Ok(wgpu::TextureFormat::Rgba16Float)
    } else {
        Ok(graph.map_or(format, |g| g.scene_color.format()))
    }
}
fn target(
    device: &wgpu::Device,
    texture: &mut Option<wgpu::Texture>,
    format: wgpu::TextureFormat,
    size: [u32; 2],
) -> Result<(), String> {
    if texture
        .as_ref()
        .is_some_and(|t| t.width() == size[0] && t.height() == size[1] && t.format() == format)
    {
        return Ok(());
    }
    let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
    let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
    let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
    let candidate = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("scene color accumulation"),
        size: wgpu::Extent3d {
            width: size[0],
            height: size[1],
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    });
    let error = pollster::block_on(internal.pop())
        .or(pollster::block_on(memory.pop()))
        .or(pollster::block_on(validation.pop()));
    if let Some(error) = error {
        return Err(error.to_string());
    }
    *texture = Some(candidate);
    Ok(())
}
impl Renderer {
    pub(super) fn copy_linear_color(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        source: &wgpu::Texture,
        target: &wgpu::TextureView,
        unassociate: bool,
        premultiply: bool,
    ) {
        self.compositor.encode(
            &self.device,
            encoder,
            source,
            target,
            (
                wgpu::TextureFormat::Rgba16Float,
                OutputTransform {
                    unassociate,
                    premultiply,
                    tone_mapping: None,
                },
                1.,
            ),
        );
    }
    pub(super) fn resolve_frame_graph(
        &self,
        frame: &Frame,
        width: u32,
        height: u32,
    ) -> Result<Option<FrameGraph>, String> {
        frame
            .graph
            .map(|key| {
                self.graphs.frame(
                    key,
                    width,
                    height,
                    frame.admission.as_ref().is_some_and(|a| !a.publish),
                )
            })
            .transpose()
    }
    pub(super) fn prepare_retained_size(
        &mut self,
        frame: &Frame,
        graph: Option<&FrameGraph>,
        size: [u32; 2],
        format: wgpu::TextureFormat,
    ) -> Result<[u32; 2], String> {
        let internal = graph.map_or(size, |g| [g.scene_color.width(), g.scene_color.height()]);
        if internal != size
            && self.compositor.resized.as_ref().is_some_and(|t| {
                [t.color.width(), t.color.height()] == internal && t.color.format() == format
            })
        {
            self.compositor.resized.as_mut().unwrap().view =
                frame.binary.as_ref().map_or(0, |v| v.view);
            return Ok(internal);
        }
        let state = self.state.as_mut().unwrap();
        if let Some(old) = state.compositor.resized.take() {
            state
                .resources
                .release_graph(&state.device, &old.keys)
                .map_err(|e| e.to_string())?;
        }
        if internal == size {
            return Ok(size);
        }
        state
            .resources
            .check_scene_capacity(
                u64::from(internal[0])
                    * u64::from(internal[1])
                    * u64::from(format.block_copy_size(None).unwrap_or(4) + 4),
                2,
            )
            .map_err(|e| e.to_string())?;
        let (color_key, color) = state
            .resources
            .create_frame_target(&state.device, internal, format)
            .map_err(|e| e.to_string())?;
        let (depth_key, depth) = match state.resources.create_frame_target(
            &state.device,
            internal,
            wgpu::TextureFormat::Depth32Float,
        ) {
            Ok(value) => value,
            Err(error) => {
                state
                    .resources
                    .release_graph(&state.device, &[color_key])
                    .map_err(|e| e.to_string())?;
                return Err(error.to_string());
            }
        };
        state.compositor.resized = Some(ResizeTarget {
            color,
            depth,
            keys: [color_key, depth_key],
            view: frame.binary.as_ref().map_or(0, |v| v.view),
        });
        state.compositor.prepare(
            &state.device,
            format,
            OutputTransform {
                unassociate: false,
                premultiply: false,
                tone_mapping: None,
            },
        )?;
        Ok(internal)
    }
    pub(super) fn prepare_frame_targets(
        &mut self,
        frame: &Frame,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        graph: Option<&FrameGraph>,
        surface: bool,
    ) -> Result<(), String> {
        self.prepare_output(frame, size, format)?;
        let scene_format = scene_format(frame, format, graph)?;
        let hdr = frame.color_pipeline.is_some();
        if hdr && u64::from(size[0]) * u64::from(size[1]) * 8 > crate::resources::upload::MAX_BYTES
        {
            return Err("HDR scene color exceeds 64 MiB per attachment".into());
        }
        let state = self.state.as_mut().unwrap();
        MultisampleTargets::prepare(
            &state.device,
            &mut state.compositor.multisample,
            scene_format,
            size,
            if frame.settings.enabled {
                1
            } else {
                frame.sample_count()
            },
        )?;
        if hdr && graph.is_none() && !frame.settings.enabled {
            target(&state.device, &mut state.compositor.hdr, scene_format, size)?;
        } else {
            state.compositor.hdr = None;
        }
        if frame.background_alpha < 1. {
            target(
                &state.device,
                &mut state.compositor.accumulation,
                scene_format,
                size,
            )?;
            state.compositor.prepare(
                &state.device,
                scene_format,
                OutputTransform {
                    unassociate: true,
                    premultiply: surface && graph.is_none() && !hdr && !frame.settings.enabled,
                    tone_mapping: None,
                },
            )?;
        } else {
            state.compositor.accumulation = None;
        }
        if frame.settings.enabled {
            state.compositor.prepare(
                &state.device,
                scene_format,
                OutputTransform {
                    unassociate: false,
                    premultiply: true,
                    tone_mapping: None,
                },
            )?;
        }
        if graph.is_some() || hdr {
            state.compositor.prepare(
                &state.device,
                format,
                OutputTransform {
                    unassociate: false,
                    premultiply: surface,
                    tone_mapping: frame.color_pipeline.map(|p| p.tone_mapping),
                },
            )?;
        }
        Ok(())
    }
    pub(super) fn encode_frame(
        &self,
        frame: &Frame,
        color: &wgpu::TextureView,
        depth: &wgpu::TextureView,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        composition: (
            Option<&FrameGraph>,
            &[Option<PreparedMaterial>],
            bool,
            &super::environment::PreparedEnvironment,
            &super::shadows::PreparedShadows,
            bool,
        ),
    ) -> wgpu::CommandEncoder {
        if let Some(target) = &self.compositor.resized {
            let mut encoder = self.encode_frame_content(
                frame,
                &target.color.create_view(&Default::default()),
                &target.depth.create_view(&Default::default()),
                format,
                size,
                composition,
            );
            self.begin_pass(&mut encoder, super::timing::Pass::ResizeComposite);
            self.compositor.encode(
                &self.device,
                &mut encoder,
                &target.color,
                color,
                (
                    format,
                    OutputTransform {
                        unassociate: false,
                        premultiply: false,
                        tone_mapping: None,
                    },
                    1.,
                ),
            );
            self.end_pass(&mut encoder, super::timing::Pass::ResizeComposite);
            encoder
        } else {
            self.encode_frame_content(frame, color, depth, format, size, composition)
        }
    }
    fn encode_frame_content(
        &self,
        frame: &Frame,
        color: &wgpu::TextureView,
        depth: &wgpu::TextureView,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        composition: (
            Option<&FrameGraph>,
            &[Option<PreparedMaterial>],
            bool,
            &super::environment::PreparedEnvironment,
            &super::shadows::PreparedShadows,
            bool,
        ),
    ) -> wgpu::CommandEncoder {
        let (graph, materials, surface, environment, shadows, load_depth) = composition;
        if frame.settings.enabled {
            return self.encode_effects(
                frame,
                color,
                depth,
                format,
                size,
                (materials, graph, environment, shadows),
            );
        }
        let final_color = color;
        let color = self.outlines.color_target(frame).unwrap_or(color);
        let scene_format = scene_format(frame, format, graph).expect("validated color pipeline");
        let hdr = frame.color_pipeline.is_some();
        let scene_texture = graph
            .map(|g| &g.scene_color)
            .or(self.compositor.hdr.as_ref());
        let scene_view = scene_texture.map(|t| t.create_view(&Default::default()));
        let output_scene_target = scene_view.as_ref().unwrap_or(color);
        let temporal_targets = self.temporal.targets(frame);
        let temporal_color = temporal_targets.map(|t| t.0.create_view(&Default::default()));
        let temporal_depth = temporal_targets.map(|t| t.1.create_view(&Default::default()));
        let scene_target = temporal_color.as_ref().unwrap_or(output_scene_target);
        let depth = temporal_depth.as_ref().unwrap_or(depth);
        let accumulation = self.compositor.accumulation.as_ref();
        let accumulation_view = accumulation.map(|t| t.create_view(&Default::default()));
        let resolve = accumulation_view.as_ref().unwrap_or(scene_target);
        let multisample = self.compositor.multisample.as_ref();
        let multisample_color = multisample.map(|t| t.color.create_view(&Default::default()));
        let multisample_depth = multisample.map(|t| t.depth.create_view(&Default::default()));
        let mut encoder = self.encode_scene(
            frame,
            (
                multisample_color.as_ref().unwrap_or(resolve),
                multisample.map(|_| resolve),
                multisample_depth.as_ref().unwrap_or(depth),
                load_depth,
            ),
            scene_format,
            size,
            (materials, graph, environment, shadows),
        );
        if let Some(accumulation) = accumulation {
            self.begin_pass(&mut encoder, super::timing::Pass::AlphaResolve);
            self.compositor.encode(
                &self.device,
                &mut encoder,
                accumulation,
                scene_target,
                (
                    scene_format,
                    OutputTransform {
                        unassociate: true,
                        premultiply: surface && graph.is_none() && !hdr && !frame.settings.enabled,
                        tone_mapping: None,
                    },
                    1.,
                ),
            );
        }
        if accumulation.is_some() {
            self.end_pass(&mut encoder, super::timing::Pass::AlphaResolve);
        }
        if frame.temporal.is_some() {
            self.begin_pass(&mut encoder, super::timing::Pass::Temporal);
        }
        self.encode_temporal(frame, output_scene_target, &mut encoder);
        if frame.temporal.is_some() {
            self.end_pass(&mut encoder, super::timing::Pass::Temporal);
        }
        if let Some(graph) = graph {
            if graph.has_after() {
                self.begin_pass(&mut encoder, super::timing::Pass::ResourceGraphAfter);
            }
            graph.encode(&mut encoder);
            if graph.has_after() {
                self.end_pass(&mut encoder, super::timing::Pass::ResourceGraphAfter);
            }
        }
        if let Some(output) = graph.map(|g| &g.output).or(self.compositor.hdr.as_ref()) {
            self.begin_pass(&mut encoder, super::timing::Pass::Output);
            self.compositor.encode(
                &self.device,
                &mut encoder,
                output,
                color,
                (
                    format,
                    OutputTransform {
                        unassociate: false,
                        premultiply: surface,
                        tone_mapping: frame.color_pipeline.map(|p| p.tone_mapping),
                    },
                    frame.color_pipeline.map_or(1., |p| p.exposure),
                ),
            );
        }
        if graph.is_some() || self.compositor.hdr.is_some() {
            self.end_pass(&mut encoder, super::timing::Pass::Output);
        }
        if self.outlines.view(frame).is_some() {
            self.begin_pass(&mut encoder, super::timing::Pass::Outlines);
        }
        self.outlines.encode(
            &self.device,
            &mut encoder,
            frame,
            final_color,
            format,
            surface,
        );
        if self.outlines.view(frame).is_some() {
            self.end_pass(&mut encoder, super::timing::Pass::Outlines);
        }
        encoder
    }
}
