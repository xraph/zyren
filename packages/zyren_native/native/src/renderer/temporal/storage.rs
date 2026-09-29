use super::Working;
pub(super) fn texture(
    device: &wgpu::Device,
    old: Option<&wgpu::Texture>,
    size: [u32; 2],
    format: wgpu::TextureFormat,
) -> wgpu::Texture {
    if let Some(old) =
        old.filter(|t| t.width() == size[0] && t.height() == size[1] && t.format() == format)
    {
        return old.clone();
    }
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some("temporal attachment"),
        size: wgpu::Extent3d {
            width: size[0],
            height: size[1],
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT
            | wgpu::TextureUsages::TEXTURE_BINDING
            | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    })
}
pub(super) fn working(device: &wgpu::Device, current: &mut Option<Working>, size: [u32; 2]) {
    if current
        .as_ref()
        .is_some_and(|w| w.color.width() == size[0] && w.color.height() == size[1])
    {
        return;
    }
    *current = None;
    *current = Some(Working {
        color: texture(device, None, size, wgpu::TextureFormat::Rgba16Float),
        depth: texture(device, None, size, wgpu::TextureFormat::Depth32Float),
        motion: texture(device, None, size, wgpu::TextureFormat::Rgba32Float),
    });
}
pub(super) fn buffer(
    device: &wgpu::Device,
    source: &wgpu::Buffer,
    old: Option<&wgpu::Buffer>,
    usage: wgpu::BufferUsages,
    copies: &mut Vec<(wgpu::Buffer, wgpu::Buffer)>,
) -> wgpu::Buffer {
    let target = old
        .filter(|b| b.size() == source.size())
        .cloned()
        .unwrap_or_else(|| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("accepted temporal geometry"),
                size: source.size(),
                usage: usage | wgpu::BufferUsages::COPY_DST,
                mapped_at_creation: false,
            })
        });
    copies.push((source.clone(), target.clone()));
    target
}
