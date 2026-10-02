use super::ResourceError;

pub fn native(id: u32) -> Result<wgpu::TextureFormat, ResourceError> {
    use wgpu::TextureFormat::*;
    Ok(match id {
        0 => Rgba8Unorm,
        1 => Rgba8UnormSrgb,
        2 => Rgba16Float,
        9 => Rgba32Float,
        10 => R32Float,
        3 => Bc7RgbaUnorm,
        4 => Bc7RgbaUnormSrgb,
        5 => Etc2Rgba8Unorm,
        6 => Etc2Rgba8UnormSrgb,
        7 | 8 => Astc {
            block: wgpu::AstcBlock::B4x4,
            channel: if id == 7 {
                wgpu::AstcChannel::Unorm
            } else {
                wgpu::AstcChannel::UnormSrgb
            },
        },
        _ => return Err(ResourceError::InvalidCommand),
    })
}
pub fn compressed(id: u32) -> bool {
    (3..=8).contains(&id)
}
pub fn srgb(id: u32) -> bool {
    matches!(id, 1 | 4 | 6 | 8)
}
pub fn level_bytes(id: u32, width: u32, height: u32) -> u64 {
    if compressed(id) {
        u64::from(width.div_ceil(4)) * u64::from(height.div_ceil(4)) * 16
    } else {
        u64::from(width)
            * u64::from(height)
            * match id {
                2 => 8,
                9 => 16,
                _ => 4,
            }
    }
}
pub fn feature(id: u32) -> wgpu::Features {
    match id {
        3 | 4 => wgpu::Features::TEXTURE_COMPRESSION_BC,
        5 | 6 => wgpu::Features::TEXTURE_COMPRESSION_ETC2,
        7 | 8 => wgpu::Features::TEXTURE_COMPRESSION_ASTC,
        _ => wgpu::Features::empty(),
    }
}
pub fn require(device: &wgpu::Device, id: u32) -> Result<wgpu::TextureFormat, ResourceError> {
    let format = native(id)?;
    if !device.features().contains(feature(id)) {
        return Err(ResourceError::InvalidUsage);
    }
    Ok(format)
}
pub fn supported_mask(device: &wgpu::Device) -> u32 {
    (0..=10)
        .filter(|id| device.features().contains(feature(*id)))
        .fold(0, |mask, id| mask | (1 << id))
}
/// Copies cover physical blocks, including padded mip tails. Row counts use blocks.
pub fn copy_layout(
    format: wgpu::TextureFormat,
    width: u32,
    height: u32,
) -> (wgpu::Extent3d, u32, u32) {
    let (bw, bh) = format.block_dimensions();
    let columns = width.div_ceil(bw);
    let rows = height.div_ceil(bh);
    (
        wgpu::Extent3d {
            width: columns * bw,
            height: rows * bh,
            depth_or_array_layers: 1,
        },
        columns * format.block_copy_size(None).unwrap(),
        rows,
    )
}
