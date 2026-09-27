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
                .contains(&wgpu::CompositeAlphaMode::Opaque)
            {
                wgpu::CompositeAlphaMode::Opaque
            } else {
                wgpu::CompositeAlphaMode::Inherit
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
