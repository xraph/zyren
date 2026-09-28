use super::Renderer;
use crate::{
    render_graph::{FrameGraph, PreparedMaterial},
    scene::Frame,
};
use std::collections::HashMap;

const OUTPUT_SHADER: &str = r#"
@group(0) @binding(0) var source: texture_2d<f32>;
@vertex fn vertex(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
  let positions = array<vec2<f32>, 3>(vec2(-1., -1.), vec2(3., -1.), vec2(-1., 3.));
  return vec4<f32>(positions[i], 0., 1.);
}
@fragment fn fragment(@builtin(position) pixel: vec4<f32>) -> @location(0) vec4<f32> {
  return textureLoad(source, vec2<i32>(pixel.xy), 0);
}
"#;
#[derive(Default)]
pub(super) struct Compositor {
    pipelines: HashMap<wgpu::TextureFormat, (wgpu::RenderPipeline, wgpu::BindGroupLayout)>,
}
impl Compositor {
    fn prepare(
        &mut self,
        device: &wgpu::Device,
        format: wgpu::TextureFormat,
    ) -> Result<(), String> {
        if self.pipelines.contains_key(&format) {
            return Ok(());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("frame output texture"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: false },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            }],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("frame output"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("frame output"),
            source: wgpu::ShaderSource::Wgsl(OUTPUT_SHADER.into()),
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
        self.pipelines.insert(format, (pipeline, layout));
        Ok(())
    }
    fn encode(
        &self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        source: &wgpu::Texture,
        target: &wgpu::TextureView,
        format: wgpu::TextureFormat,
    ) {
        let (pipeline, layout) = &self.pipelines[&format];
        let view = source.create_view(&Default::default());
        let binding = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("frame output"),
            layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(&view),
            }],
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
impl Renderer {
    pub(super) fn resolve_frame_graph(
        &self,
        frame: &Frame,
        width: u32,
        height: u32,
    ) -> Result<Option<FrameGraph>, String> {
        frame
            .graph
            .map(|key| self.graphs.frame(key, width, height))
            .transpose()
    }
    pub(super) fn prepare_frame_pipelines(
        &mut self,
        frame: &Frame,
        format: wgpu::TextureFormat,
        graph: Option<&FrameGraph>,
    ) -> Result<(), String> {
        let scene_format = graph.map_or(format, |g| g.scene_color.format());
        self.prepare_pipelines(frame, scene_format)?;
        if graph.is_some() {
            let state = self.state.as_mut().unwrap();
            state.compositor.prepare(&state.device, format)?;
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
        composition: (Option<&FrameGraph>, &[Option<PreparedMaterial>]),
    ) -> wgpu::CommandEncoder {
        let (graph, materials) = composition;
        let Some(graph) = graph else {
            return self.encode_scene(frame, color, depth, format, size, materials);
        };
        let scene_view = graph.scene_color.create_view(&Default::default());
        let mut encoder = self.encode_scene(
            frame,
            &scene_view,
            depth,
            graph.scene_color.format(),
            size,
            materials,
        );
        graph.encode(&mut encoder);
        self.compositor
            .encode(&self.device, &mut encoder, &graph.output, color, format);
        encoder
    }
}
