use super::*;

pub(super) struct Multisample {
    pub color: wgpu::TextureView,
    pub depth: wgpu::TextureView,
}
impl Multisample {
    pub fn new(device: &wgpu::Device, size: [u32; 2]) -> Self {
        let create = |format| {
            device
                .create_texture(&wgpu::TextureDescriptor {
                    label: Some("view 4x MSAA"),
                    size: wgpu::Extent3d {
                        width: size[0],
                        height: size[1],
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: 1,
                    sample_count: 4,
                    dimension: wgpu::TextureDimension::D2,
                    format,
                    usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                        | wgpu::TextureUsages::TEXTURE_BINDING,
                    view_formats: &[],
                })
                .create_view(&Default::default())
        };
        Self {
            color: create(effects::HDR),
            depth: create(wgpu::TextureFormat::Depth32Float),
        }
    }
}
pub(super) fn pipeline(device: &wgpu::Device, reversed_depth: bool) -> wgpu::RenderPipeline {
    let shader = device.create_shader_module(wgpu::include_wgsl!("depth_resolve.wgsl"));
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("nearest covered depth resolve"),
        layout: None,
        vertex: wgpu::VertexState {
            module: &shader,
            entry_point: Some("vertex"),
            compilation_options: Default::default(),
            buffers: &[],
        },
        fragment: Some(wgpu::FragmentState {
            module: &shader,
            entry_point: Some(if reversed_depth {
                "reversed_fragment"
            } else {
                "fragment"
            }),
            compilation_options: Default::default(),
            targets: &[],
        }),
        primitive: Default::default(),
        depth_stencil: Some(wgpu::DepthStencilState {
            format: wgpu::TextureFormat::Depth32Float,
            depth_write_enabled: Some(true),
            depth_compare: Some(wgpu::CompareFunction::Always),
            stencil: Default::default(),
            bias: Default::default(),
        }),
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    })
}
pub(super) fn resolve(
    device: &wgpu::Device,
    encoder: &mut wgpu::CommandEncoder,
    pipeline: &wgpu::RenderPipeline,
    input: &wgpu::TextureView,
    output: &wgpu::TextureView,
    clear: f32,
) {
    let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("multisample depth"),
        layout: &pipeline.get_bind_group_layout(0),
        entries: &[wgpu::BindGroupEntry {
            binding: 0,
            resource: wgpu::BindingResource::TextureView(input),
        }],
    });
    let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
        label: Some("depth resolve"),
        color_attachments: &[],
        depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
            view: output,
            depth_ops: Some(wgpu::Operations {
                load: wgpu::LoadOp::Clear(clear),
                store: wgpu::StoreOp::Store,
            }),
            stencil_ops: None,
        }),
        ..Default::default()
    });
    pass.set_pipeline(pipeline);
    pass.set_bind_group(0, &group, &[]);
    pass.draw(0..3, 0..1);
}
