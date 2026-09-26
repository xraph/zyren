use crate::{renderer::Renderer, scene::Frame};
use objc2::{rc::Retained, runtime::ProtocolObject};
use objc2_metal::{
    MTLDevice, MTLPixelFormat, MTLResource, MTLTexture, MTLTextureType, MTLTextureUsage,
};

impl Renderer {
    pub fn metal_device(&self) -> Result<Retained<ProtocolObject<dyn MTLDevice>>, String> {
        // SAFETY: borrow the backend device without mutating its state or destroying it.
        let device = unsafe { self.device.as_hal::<wgpu::hal::api::Metal>() }
            .ok_or("renderer is not using Metal")?;
        Ok(device.raw_device().clone())
    }

    /// Render directly into an Apple texture owned by a native presentation adapter.
    ///
    /// # Safety
    /// The caller must own exclusive GPU/CPU access to the texture until this
    /// call succeeds. On failure after submission, no consumer may access it
    /// until actual GPU completion. The retained Metal object must remain valid.
    pub unsafe fn render_to_metal(
        &mut self,
        frame: &Frame,
        texture: Retained<ProtocolObject<dyn MTLTexture>>,
    ) -> Result<(), String> {
        let device = self.metal_device()?;
        if Retained::as_ptr(&texture.device()) != Retained::as_ptr(&device)
            || texture.textureType() != MTLTextureType::Type2D
            || texture.pixelFormat() != MTLPixelFormat::BGRA8Unorm_sRGB
            || texture.mipmapLevelCount() != 1
            || texture.arrayLength() != 1
            || texture.sampleCount() != 1
            || !texture.usage().contains(MTLTextureUsage::RenderTarget)
        {
            return Err("surface texture must use the renderer's Metal device and BGRA8 sRGB render-target layout".into());
        }
        let width = u32::try_from(texture.width()).map_err(|_| "surface width exceeds u32")?;
        let height = u32::try_from(texture.height()).map_err(|_| "surface height exceeds u32")?;
        crate::scene::pixel_len(width, height)?;
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        // SAFETY: the checks above establish device identity and exact layout.
        // The retained object moves into HAL ownership. The caller grants exclusive
        // access, and the render pass clears every pixel before sampling is allowed.
        let hal_texture = unsafe {
            wgpu::hal::metal::Device::texture_from_raw(
                texture,
                wgpu::TextureFormat::Bgra8UnormSrgb,
                MTLTextureType::Type2D,
                1,
                1,
                wgpu::hal::CopyExtent {
                    width,
                    height,
                    depth: 1,
                },
                None,
            )
        };
        let descriptor = wgpu::TextureDescriptor {
            label: Some("Apple shared color"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Bgra8UnormSrgb,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        };
        // SAFETY: descriptor matches the native object; previous content is
        // discarded. Producer completion is observed before returning success.
        let imported = unsafe {
            self.device
                .create_texture_from_hal::<wgpu::hal::api::Metal>(
                    hal_texture,
                    &descriptor,
                    wgpu::TextureUses::UNINITIALIZED,
                )
        };
        self.render_to_surface(frame, imported, width, height)
    }
}
