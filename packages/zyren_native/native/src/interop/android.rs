use std::{ffi::c_void, ptr::NonNull};

use crate::renderer::Renderer;
use wgpu::rwh::{AndroidDisplayHandle, AndroidNdkWindowHandle, RawDisplayHandle, RawWindowHandle};

#[link(name = "android")]
unsafe extern "C" {
    fn ANativeWindow_acquire(window: *mut c_void);
    fn ANativeWindow_release(window: *mut c_void);
}

struct Window(NonNull<c_void>);
// SAFETY: ANativeWindow references are thread safe; renderer access is serialized.
unsafe impl Send for Window {}
unsafe impl Sync for Window {}
impl Drop for Window {
    fn drop(&mut self) {
        unsafe { ANativeWindow_release(self.0.as_ptr()) };
    }
}

// Drop the acquired image before the swapchain, then release the native window.
pub(crate) struct AndroidTarget {
    pending: Option<wgpu::SurfaceTexture>,
    surface: wgpu::Surface<'static>,
    window: Window,
    config: wgpu::SurfaceConfiguration,
    presented: u64,
}

fn with_renderer<T: Default>(
    handle: u64,
    operation: impl FnOnce(&mut Renderer) -> Result<T, String>,
) -> T {
    crate::guard(|| {
        let renderer = crate::registry()
            .lock()
            .map_err(|_| "registry poisoned")?
            .get(&handle)
            .cloned()
            .ok_or("invalid renderer")?;
        let mut renderer = renderer.lock().map_err(|_| "renderer poisoned")?;
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| operation(&mut renderer))) {
            Ok(result) => result,
            Err(_) => {
                renderer.failure =
                    Some("Vulkan surface operation panicked; recreate the renderer".into());
                Err(renderer.failure.clone().unwrap())
            }
        }
    })
}

/// Native adapter only. Retains its own window reference through GPU retirement.
/// # Safety
/// `window` is a live ANativeWindow obtained from the current Java Surface.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_android_attach(
    handle: u64,
    window: *mut c_void,
    width: u32,
    height: u32,
) -> u32 {
    with_renderer(handle, |renderer| {
        crate::scene::pixel_len(width, height)?;
        if let Some(error) = &renderer.failure {
            return Err(error.clone());
        }
        if renderer.backend != wgpu::Backend::Vulkan {
            return Err("Android requires Vulkan".into());
        }
        let pointer = NonNull::new(window).ok_or("null native window")?;
        if let Some(target) = &renderer.android
            && target.window.0 == pointer
            && target.config.width == width
            && target.config.height == height
        {
            return Ok(1);
        }
        // A previous frame has completed before JNI can resize or replace this target.
        renderer.android = None;
        unsafe { ANativeWindow_acquire(window) };
        let window = Window(pointer);
        // SAFETY: Window owns a reference and drops after this Surface. Only the
        // serialized renderer can configure, acquire, submit or destroy it.
        let surface = unsafe {
            renderer
                .instance
                .create_surface_unsafe(wgpu::SurfaceTargetUnsafe::RawHandle {
                    raw_display_handle: Some(
                        RawDisplayHandle::Android(AndroidDisplayHandle::new()),
                    ),
                    raw_window_handle: RawWindowHandle::AndroidNdk(AndroidNdkWindowHandle::new(
                        pointer,
                    )),
                })
        }
        .map_err(|e| format!("Vulkan Android surface: {e}"))?;
        let capabilities = surface.get_capabilities(&renderer.adapter);
        let format = [
            wgpu::TextureFormat::Rgba8UnormSrgb,
            wgpu::TextureFormat::Bgra8UnormSrgb,
        ]
        .into_iter()
        .find(|format| capabilities.formats.contains(format))
        .ok_or_else(|| {
            format!(
                "Vulkan surface lacks an sRGB color target: {:?}",
                capabilities.formats
            )
        })?;
        if !capabilities
            .present_modes
            .contains(&wgpu::PresentMode::Fifo)
        {
            return Err("Vulkan surface lacks FIFO presentation".into());
        }
        let config = wgpu::SurfaceConfiguration {
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            format,
            color_space: wgpu::SurfaceColorSpace::Auto,
            width,
            height,
            present_mode: wgpu::PresentMode::Fifo,
            desired_maximum_frame_latency: 2,
            alpha_mode: if capabilities
                .alpha_modes
                .contains(&wgpu::CompositeAlphaMode::PreMultiplied)
            {
                wgpu::CompositeAlphaMode::PreMultiplied
            } else if capabilities
                .alpha_modes
                .contains(&wgpu::CompositeAlphaMode::Inherit)
            {
                // SurfaceProducer consumes RGBA images as Flutter textures.
                wgpu::CompositeAlphaMode::Inherit
            } else {
                return Err("Vulkan surface lacks premultiplied alpha presentation".into());
            },
            view_formats: vec![],
        };
        // Retain the target before configure, including its panic path.
        renderer.android = Some(AndroidTarget {
            pending: None,
            surface,
            window,
            config,
            presented: 0,
        });
        let target = renderer.android.as_ref().unwrap();
        target.surface.configure(&renderer.device, &target.config);
        renderer.android_generation += 1;
        Ok(1)
    })
}

/// Returns 1 for completed rendering, 2 when acquisition should be retried.
/// # Safety
/// `json` addresses `length` readable bytes. JNI serializes calls for this handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_android_render(handle: u64, json: *const u8, length: usize) -> u32 {
    with_renderer(handle, |renderer| {
        if let Some(error) = &renderer.failure {
            return Err(error.clone());
        }
        if json.is_null() || length == 0 || length > 128 * 1024 * 1024 {
            return Err("invalid scene buffer".into());
        }
        let frame = renderer.decode_scene(unsafe { std::slice::from_raw_parts(json, length) })?;
        let target = renderer.android.as_mut().ok_or("surface is detached")?;
        if target.pending.is_some() {
            return Err("a frame is already pending publication".into());
        }
        let texture = match target.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture)
            | wgpu::CurrentSurfaceTexture::Suboptimal(texture) => texture,
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => {
                return Ok(2);
            }
            wgpu::CurrentSurfaceTexture::Outdated | wgpu::CurrentSurfaceTexture::Lost => {
                let target = renderer.android.as_ref().unwrap();
                target.surface.configure(&renderer.device, &target.config);
                return Ok(2);
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                return Err("Vulkan surface acquisition failed validation".into());
            }
        };
        let image = texture.texture.clone();
        let (width, height) = (target.config.width, target.config.height);
        target.pending = Some(texture);
        renderer.render_to_surface(&frame, image, width, height)?;
        Ok(1)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn fg_android_present(handle: u64) -> u32 {
    with_renderer(handle, |renderer| {
        if let Some(error) = &renderer.failure {
            return Err(error.clone());
        }
        let target = renderer.android.as_mut().ok_or("surface is detached")?;
        let frame = target
            .pending
            .take()
            .ok_or("no completed frame to publish")?;
        target.presented += 1;
        renderer.queue.present(frame);
        Ok(1)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn fg_android_detach(handle: u64) -> u32 {
    with_renderer(handle, |renderer| {
        if renderer.failure.is_none() {
            renderer.android = None;
        }
        Ok(1)
    })
}

/// # Safety
/// A non-null buffer addresses `capacity` writable bytes. Returns UTF-8 length.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_android_info(handle: u64, buffer: *mut u8, capacity: usize) -> usize {
    with_renderer(handle, |renderer| {
        let info = renderer.adapter.get_info();
        let target = renderer.android.as_ref();
        let bytes = serde_json::to_vec(&serde_json::json!({
            "backend": format!("{:?}", info.backend), "adapter": info.name,
            "driver": info.driver, "driverInfo": info.driver_info,
            "alphaMode": target.map(|t| format!("{:?}", t.config.alpha_mode)),
            "format": target.map(|t| format!("{:?}", t.config.format)),
            "requestedFrameLatency": target.map(|t| t.config.desired_maximum_frame_latency),
            "readbackBytes": renderer.counters().readback_bytes,
            "submitted": renderer.counters().submitted_frames,
            "surfaceGeneration": renderer.android_generation,
        }))
        .map_err(|e| e.to_string())?;
        if !buffer.is_null() && capacity >= bytes.len() {
            unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer, bytes.len()) };
        }
        Ok(bytes.len())
    })
}

/// Returns the native Vulkan handles for a serialized platform adapter.
/// # Safety
/// `output` addresses six u64 values. Handles are borrowed until renderer disposal.
/// The caller must serialize all queue/device access with this renderer's API.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_android_vulkan_context(handle: u64, output: *mut u64) -> u32 {
    use ash::vk::Handle;
    with_renderer(handle, |renderer| {
        if output.is_null() {
            return Err("null Vulkan context output".into());
        }
        let device = unsafe { renderer.device.as_hal::<wgpu::hal::api::Vulkan>() }
            .ok_or("renderer is not Vulkan")?;
        let extensions = device.enabled_device_extensions();
        if !extensions.contains(&ash::android::external_memory_android_hardware_buffer::NAME)
            || !extensions.contains(&ash::ext::queue_family_foreign::NAME)
            || !extensions.contains(&ash::ext::swapchain_maintenance1::NAME)
        {
            return Err(
                "Vulkan device lacks Android hardware-buffer imports or presentation retirement"
                    .into(),
            );
        }
        let instance = device.shared_instance().raw_instance();
        let mut ycbcr = ash::vk::PhysicalDeviceSamplerYcbcrConversionFeatures::default();
        let mut features = ash::vk::PhysicalDeviceFeatures2::default().push_next(&mut ycbcr);
        unsafe {
            instance.get_physical_device_features2(device.raw_physical_device(), &mut features);
        }
        if ycbcr.sampler_ycbcr_conversion == 0 {
            return Err("Vulkan device lacks YCbCr conversion".into());
        }
        let values = [
            instance.handle().as_raw(),
            device.raw_physical_device().as_raw(),
            device.raw_device().handle().as_raw(),
            device.raw_queue().as_raw(),
            device.queue_family_index() as u64,
            renderer.counters().readback_bytes,
        ];
        unsafe {
            std::ptr::copy_nonoverlapping(values.as_ptr(), output, values.len());
        }
        Ok(1)
    })
}

/// Renders to a platform-owned Vulkan color image, with no CPU pixel transfer.
/// # Safety
/// The caller passes a live image allocated on `device`, matching RGBA8 sRGB,
/// dimensions and COLOR_ATTACHMENT|SAMPLED usage, one mip/layer/sample. Its layout
/// is UNDEFINED and queue ownership belongs to the exported graphics family.
/// The packet is readable for `length` bytes. Exclusive access lasts through
/// success; on failure the caller must wait device idle before freeing images.
/// Nonzero `depth_image` is D32Float on the same device with matching size and
/// DEPTH_STENCIL_ATTACHMENT usage. Every pixel is initialized, its layout is
/// DEPTH_STENCIL_ATTACHMENT_OPTIMAL, and all producer GPU writes have completed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_android_render_image(
    handle: u64,
    packet: *const u8,
    length: usize,
    device: u64,
    image: u64,
    depth_image: u64,
    width: u32,
    height: u32,
) -> u32 {
    use ash::vk::Handle;
    with_renderer(handle, |renderer| {
        if packet.is_null() || length == 0 || length > 128 * 1024 * 1024 || image == 0 {
            return Err("invalid Vulkan image or scene packet".into());
        }
        crate::scene::pixel_len(width, height)?;
        if let Some(error) = &renderer.failure {
            return Err(error.clone());
        }
        let frame = renderer.decode_scene(unsafe { std::slice::from_raw_parts(packet, length) })?;
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        let desc = wgpu::hal::TextureDescriptor {
            label: Some("Android shared color"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUses::COLOR_TARGET | wgpu::TextureUses::RESOURCE,
            memory_flags: wgpu::hal::MemoryFlags::empty(),
            view_formats: vec![],
        };
        let raw = {
            let hal = unsafe { renderer.device.as_hal::<wgpu::hal::api::Vulkan>() }
                .ok_or("renderer is not Vulkan")?;
            if device != hal.raw_device().handle().as_raw() {
                return Err("Vulkan device identity mismatch".into());
            }
            unsafe {
                hal.texture_from_raw(
                    ash::vk::Image::from_raw(image),
                    &desc,
                    Some(Box::new(|| {})),
                    wgpu::hal::vulkan::TextureMemory::External,
                )
            }
        };
        let desc = wgpu::TextureDescriptor {
            label: Some("Android shared color"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        };
        let target = unsafe {
            renderer
                .device
                .create_texture_from_hal::<wgpu::hal::api::Vulkan>(
                    raw,
                    &desc,
                    wgpu::TextureUses::UNINITIALIZED,
                )
        };
        let depth = if depth_image != 0 {
            Renderer::check_external_depth_frame(&frame)?;
            let desc = wgpu::hal::TextureDescriptor {
                label: Some("Android initialized depth"),
                size,
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUses::DEPTH_STENCIL_WRITE,
                memory_flags: wgpu::hal::MemoryFlags::empty(),
                view_formats: vec![],
            };
            let raw = {
                let hal = unsafe { renderer.device.as_hal::<wgpu::hal::api::Vulkan>() }
                    .ok_or("renderer is not Vulkan")?;
                unsafe {
                    hal.texture_from_raw(
                        ash::vk::Image::from_raw(depth_image),
                        &desc,
                        Some(Box::new(|| {})),
                        wgpu::hal::vulkan::TextureMemory::External,
                    )
                }
            };
            let desc = wgpu::TextureDescriptor {
                label: Some("Android initialized depth"),
                size,
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            };
            Some(unsafe {
                renderer
                    .device
                    .create_texture_from_hal::<wgpu::hal::api::Vulkan>(
                        raw,
                        &desc,
                        wgpu::TextureUses::DEPTH_STENCIL_WRITE,
                    )
            })
        } else {
            None
        };
        if let Err(error) =
            renderer.render_to_surface_with_depth(&frame, target, depth, width, height)
        {
            // The platform caller owns the allocations. Complete all possible
            // GPU access and release borrowed views before returning a failure.
            let idle = {
                let hal = unsafe { renderer.device.as_hal::<wgpu::hal::api::Vulkan>() }
                    .ok_or("renderer is not Vulkan")?;
                unsafe { hal.raw_device().device_wait_idle() }
            };
            renderer.failure = Some(error.clone());
            if idle.is_ok() || idle == Err(ash::vk::Result::ERROR_DEVICE_LOST) {
                renderer.release_completed_external_targets();
            }
            return Err(error);
        }
        Ok(1)
    })
}
