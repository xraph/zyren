use crate::{renderer::Renderer, scene::Frame};
use objc2::{
    rc::Retained,
    runtime::{AnyObject, ProtocolObject},
};
use objc2_metal::{
    MTLCommandBuffer, MTLCommandBufferStatus, MTLDevice, MTLPixelFormat, MTLResource, MTLTexture,
    MTLTextureType, MTLTextureUsage,
};

/// Keeps the display pool's lease alive through failed GPU retirement.
pub(crate) struct DrawableOwner(#[allow(dead_code)] Retained<AnyObject>);
// SAFETY: callers pass a Metal drawable whose retain/release is thread safe.
// The object is never messaged here; Renderer serializes all GPU access.
unsafe impl Send for DrawableOwner {}

/// Native adapter only. The caller releases the returned +1 MTLDevice reference.
#[unsafe(no_mangle)]
pub extern "C" fn fg_metal_copy_device(handle: u64) -> *mut std::ffi::c_void {
    crate::guard(|| {
        let renderer = crate::registry()
            .lock()
            .map_err(|_| "registry poisoned")?
            .get(&handle)
            .cloned()
            .ok_or("invalid renderer")?;
        let renderer = renderer.lock().map_err(|_| "renderer poisoned")?;
        Ok(Retained::into_raw(renderer.metal_device()?).cast())
    })
}

/// CPU pixel transfer bytes for a native adapter's renderer.
#[unsafe(no_mangle)]
pub extern "C" fn fg_metal_readback_bytes(handle: u64) -> u64 {
    crate::guard(|| {
        let renderer = crate::registry()
            .lock()
            .map_err(|_| "registry poisoned")?
            .get(&handle)
            .cloned()
            .ok_or("invalid renderer")?;
        let renderer = renderer.lock().map_err(|_| "renderer poisoned")?;
        Ok(renderer.counters().readback_bytes)
    })
}

/// Renders into a native adapter's drawable without reading pixels on the CPU.
/// Returns 1 on success; otherwise use fg_last_error on this thread and dispose.
///
/// # Safety
/// `json` addresses `length` readable bytes. `texture` is a live MTLTexture and
/// `owner` is its live CAMetalDrawable. Both support retain/release on any thread.
/// The caller grants exclusive texture access until success. On failure, Rust
/// retains the drawable until renderer retirement has released GPU ownership.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_metal_render_texture(
    handle: u64,
    json: *const u8,
    length: usize,
    texture: *mut std::ffi::c_void,
    owner: *mut std::ffi::c_void,
) -> u32 {
    crate::guard(|| {
        if json.is_null()
            || texture.is_null()
            || owner.is_null()
            || length == 0
            || length > 128 * 1024 * 1024
        {
            return Err("invalid native drawable input".into());
        }
        let renderer = crate::registry()
            .lock()
            .map_err(|_| "registry poisoned")?
            .get(&handle)
            .cloned()
            .ok_or("invalid renderer")?;
        let mut renderer = renderer.lock().map_err(|_| "renderer poisoned")?;
        let frame = renderer.decode_scene(unsafe { std::slice::from_raw_parts(json, length) })?;
        if let Some(error) = &renderer.failure {
            return Err(error.clone());
        }
        // SAFETY: the caller owns both objects throughout this call. Retain an
        // independent drawable lease before any work can reach the GPU.
        renderer.drawable_owner = Some(DrawableOwner(
            unsafe { Retained::retain(owner.cast::<AnyObject>()) }.unwrap(),
        ));
        let texture =
            unsafe { Retained::retain(texture.cast::<ProtocolObject<dyn MTLTexture>>()) }.unwrap();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| unsafe {
            renderer.render_to_metal(&frame, texture)
        }))
        .unwrap_or_else(|_| Err("Metal drawable rendering panicked".into()));
        match result {
            Ok(()) => {
                renderer.drawable_owner = None;
                Ok(1)
            }
            Err(error) => {
                renderer.failure = Some(error.clone());
                Err(error)
            }
        }
    })
}

pub(crate) struct MetalCompletion(Vec<Retained<ProtocolObject<dyn MTLCommandBuffer>>>);
impl MetalCompletion {
    pub(crate) fn capture(queue: &wgpu::Queue) -> Result<Self, String> {
        // SAFETY: the renderer serializes submission and capture. Only retained
        // command handles cross this borrow; none are encoded into or committed.
        let queue = unsafe { queue.as_hal::<wgpu::hal::api::Metal>() }
            .ok_or("Metal queue is unavailable")?;
        // SAFETY: handles are used only to inspect execution status.
        let commands = unsafe { queue.take_submitted_commands() };
        if commands.is_empty() {
            return Err("Metal submission has no observable commands".into());
        }
        Ok(Self(commands))
    }
    /// Elapsed GPU execution across this submission's completed command buffers.
    /// Includes gaps between buffers, excludes CPU encoding and queue wait.
    pub(crate) fn gpu_time_ns(&self) -> Option<u64> {
        let mut start = f64::INFINITY;
        let mut end: f64 = 0.0;
        for command in &self.0 {
            if command.status() != MTLCommandBufferStatus::Completed {
                return None;
            }
            let begin = command.GPUStartTime();
            let finish = command.GPUEndTime();
            if !begin.is_finite() || !finish.is_finite() || begin <= 0.0 || finish < begin {
                return None;
            }
            start = start.min(begin);
            end = end.max(finish);
        }
        let nanos = (end - start) * 1_000_000_000.0;
        (nanos.is_finite() && nanos >= 0.0 && nanos < u64::MAX as f64).then_some(nanos as u64)
    }
    pub(crate) fn check(&self) -> Result<(), String> {
        for command in &self.0 {
            completion_result(
                command.status(),
                command
                    .error()
                    .map(|error| error.localizedDescription().to_string()),
            )?;
        }
        Ok(())
    }
}

fn completion_result(status: MTLCommandBufferStatus, error: Option<String>) -> Result<(), String> {
    if status == MTLCommandBufferStatus::Completed && error.is_none() {
        return Ok(());
    }
    Err(format!(
        "Metal execution did not succeed ({status:?}): {}",
        error.unwrap_or_else(|| "command is not completed".into())
    ))
}

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

#[cfg(test)]
mod tests {
    use super::*;
    use objc2_metal::MTLCommandBufferStatus;

    #[test]
    fn completed_fence_does_not_accept_failed_or_pending_metal_execution() {
        for status in [
            MTLCommandBufferStatus::Error,
            MTLCommandBufferStatus::Scheduled,
            MTLCommandBufferStatus::Committed,
            MTLCommandBufferStatus::NotEnqueued,
        ] {
            assert!(completion_result(status, None).is_err());
        }
        assert!(completion_result(MTLCommandBufferStatus::Completed, None).is_ok());
        assert!(
            completion_result(MTLCommandBufferStatus::Completed, Some("GPU failed".into()))
                .is_err()
        );
    }
}
