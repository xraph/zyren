pub(super) struct Tables {
    views: [wgpu::TextureView; 2],
}
impl Tables {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Self {
        let views = [
            include_bytes!("ltc/ltc_1.bin"),
            include_bytes!("ltc/ltc_2.bin"),
        ]
        .map(|bytes| {
            let texture = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("rectangular light LTC table"),
                size: wgpu::Extent3d {
                    width: 64,
                    height: 64,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba32Float,
                usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
                view_formats: &[],
            });
            queue.write_texture(
                texture.as_image_copy(),
                bytes,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(64 * 16),
                    rows_per_image: Some(64),
                },
                texture.size(),
            );
            texture.create_view(&Default::default())
        });
        Self { views }
    }
    pub fn entries(&self) -> [wgpu::BindGroupEntry<'_>; 2] {
        std::array::from_fn(|i| wgpu::BindGroupEntry {
            binding: 11 + i as u32,
            resource: wgpu::BindingResource::TextureView(&self.views[i]),
        })
    }
}
pub(super) fn layout_entries() -> Vec<wgpu::BindGroupLayoutEntry> {
    (11..13)
        .map(|binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: false },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        })
        .collect()
}
