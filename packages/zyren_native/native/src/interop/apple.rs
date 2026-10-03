use super::{SurfaceError, abi::*};
use std::{ffi::c_void, mem::size_of};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Fg2FrameReceipt {
    pub struct_size: u32,
    pub abi_version: u32,
    pub epoch: u64,
    pub frame_id: u64,
    pub resident_bytes: u64,
    pub readback_bytes: u64,
}
impl Default for Fg2FrameReceipt {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            abi_version: 2,
            epoch: 0,
            frame_id: 0,
            resident_bytes: 0,
            readback_bytes: 0,
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fg2_apple_available() -> u32 {
    u32::from(cfg!(target_vendor = "apple"))
}

#[unsafe(no_mangle)]
pub extern "C" fn fg2_apple_live_buffers() -> u64 {
    platform::live_buffers()
}
#[unsafe(no_mangle)]
pub extern "C" fn fg2_apple_presented_frames() -> u64 {
    platform::presented_frames()
}
#[unsafe(no_mangle)]
pub extern "C" fn fg2_apple_readback_bytes() -> u64 {
    platform::readback_bytes()
}

/// # Safety
/// Records have valid headers and declared writable capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_apple_attach(
    handle: u64,
    key: Fg2SurfaceKey,
    output: *mut Fg2SurfaceSnapshot,
    error: *mut Fg2Error,
) -> u32 {
    unsafe { call(output, error, || platform::attach(handle, key)) }
}

/// # Safety
/// JSON addresses length readable bytes (1..128 MiB). Output and error records
/// have valid headers and writable capacities and do not alias input storage.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_apple_render(
    handle: u64,
    key: Fg2SurfaceKey,
    epoch: u64,
    frame_id: u64,
    json: *const u8,
    length: u64,
    output: *mut Fg2FrameReceipt,
    error: *mut Fg2Error,
) -> u32 {
    unsafe {
        call(output, error, || {
            if json.is_null() || length == 0 || length > 128 * 1024 * 1024 {
                if let Some(renderer) = crate::registry()
                    .lock()
                    .map_err(|_| SurfaceError::Internal)?
                    .get(&handle)
                    .cloned()
                {
                    renderer
                        .lock()
                        .map_err(|_| SurfaceError::Internal)?
                        .begin_profile();
                }
                return Err(SurfaceError::InvalidArgument);
            }
            platform::render(
                handle,
                key,
                epoch,
                frame_id,
                std::slice::from_raw_parts(json, length as usize),
            )
        })
    }
}

/// Returns a retained CVPixelBuffer for the native Flutter raster callback.
/// No pointer from this function may cross into Dart application code.
#[unsafe(no_mangle)]
pub extern "C" fn fg2_apple_copy_pixel_buffer(key: Fg2SurfaceKey) -> *mut c_void {
    std::panic::catch_unwind(|| platform::copy_buffer(key)).unwrap_or(std::ptr::null_mut())
}

/// # Safety
/// Buffer is a retained CVPixelBuffer returned by fg2_apple_copy_pixel_buffer.
pub unsafe fn release_pixel_buffer(buffer: *mut c_void) {
    unsafe { platform::release_buffer(buffer) }
}

pub(crate) fn detach(key: Fg2SurfaceKey) {
    platform::detach(key);
}
pub(crate) fn close_renderer_surfaces(handle: u64) {
    platform::close_renderer(handle);
}

#[cfg(target_vendor = "apple")]
mod platform {
    use super::*;
    use crate::interop::{LeaseId, SurfaceKey, SurfaceState};
    use objc2::{rc::Retained, runtime::ProtocolObject};
    use objc2_metal::MTLTexture;
    use std::{
        collections::HashMap,
        sync::{Mutex, OnceLock},
    };

    unsafe extern "C" {
        fn fg_apple_allocation_size(width: u32, height: u32) -> u64;
        fn fg_apple_buffer_create(
            width: u32,
            height: u32,
            context: *mut c_void,
            release: extern "C" fn(*mut c_void),
        ) -> *mut c_void;
        fn fg_apple_buffer_texture(
            buffer: *mut c_void,
            device: *mut c_void,
        ) -> *mut ProtocolObject<dyn MTLTexture>;
        fn fg_apple_buffer_retain(buffer: *mut c_void);
        fn fg_apple_buffer_release(buffer: *mut c_void);
    }
    use std::sync::atomic::{AtomicU64, Ordering};
    static LIVE: AtomicU64 = AtomicU64::new(0);
    static PRESENTED: AtomicU64 = AtomicU64::new(0);
    static READBACK: AtomicU64 = AtomicU64::new(0);
    pub(super) fn live_buffers() -> u64 {
        LIVE.load(Ordering::Acquire)
    }
    pub(super) fn presented_frames() -> u64 {
        PRESENTED.load(Ordering::Acquire)
    }
    pub(super) fn readback_bytes() -> u64 {
        READBACK.load(Ordering::Acquire)
    }
    struct Buffer(*mut c_void);
    // SAFETY: only reference ownership moves between threads. Pixels are written
    // exclusively by the producer and published after successful GPU completion.
    unsafe impl Send for Buffer {}
    impl Drop for Buffer {
        fn drop(&mut self) {
            unsafe { fg_apple_buffer_release(self.0) }
        }
    }
    struct Attachment {
        renderer: u64,
        epoch: u64,
        published: Option<Buffer>,
    }
    type Attachments = HashMap<(u64, u64), Attachment>;
    static ATTACHMENTS: OnceLock<Mutex<Attachments>> = OnceLock::new();
    fn attachments() -> &'static Mutex<Attachments> {
        ATTACHMENTS.get_or_init(Mutex::default)
    }
    struct Allocation {
        key: SurfaceKey,
        lease: LeaseId,
    }
    extern "C" fn released(context: *mut c_void) {
        // SAFETY: one allocation guard owns this Box and calls once at dealloc.
        let allocation = unsafe { Box::from_raw(context.cast::<Allocation>()) };
        LIVE.fetch_sub(1, Ordering::AcqRel);
        if let Ok(mut registry) = registry().lock()
            && let Ok(session) = registry.get_mut(allocation.key)
        {
            let _ = session.allocation_released(allocation.lease);
        }
    }
    pub(super) fn attach(
        handle: u64,
        key: Fg2SurfaceKey,
    ) -> Result<Fg2SurfaceSnapshot, SurfaceError> {
        let checked = key.checked()?;
        let renderer = crate::registry()
            .lock()
            .map_err(|_| SurfaceError::Internal)?
            .get(&handle)
            .cloned()
            .ok_or(SurfaceError::StaleKey)?;
        renderer
            .lock()
            .map_err(|_| SurfaceError::Internal)?
            .metal_device()
            .map_err(|_| SurfaceError::Internal)?;
        let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
        let session = registry.get_mut(checked)?;
        let mut views = attachments().lock().map_err(|_| SurfaceError::Internal)?;
        session.activate()?;
        views.insert(
            (checked.slot, checked.generation),
            Attachment {
                renderer: handle,
                epoch: session.epoch(),
                published: None,
            },
        );
        Ok(snapshot(checked, session))
    }
    pub(super) fn render(
        handle: u64,
        key: Fg2SurfaceKey,
        epoch: u64,
        frame_id: u64,
        bytes: &[u8],
    ) -> Result<Fg2FrameReceipt, SurfaceError> {
        let renderer = crate::registry()
            .lock()
            .map_err(|_| SurfaceError::Internal)?
            .get(&handle)
            .cloned()
            .ok_or(SurfaceError::StaleKey)?;
        let mut renderer = renderer.lock().map_err(|_| SurfaceError::Internal)?;
        renderer.begin_profile();
        let checked = key.checked()?;
        let frame = renderer
            .decode_scene(bytes)
            .map_err(|_| SurfaceError::InvalidArgument)?;
        let device = renderer
            .metal_device()
            .map_err(|_| SurfaceError::Internal)?;
        let (width, height, lease) = {
            let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
            let session = registry.get_mut(checked)?;
            if session.epoch() != epoch {
                return Err(SurfaceError::StaleEpoch);
            }
            let views = attachments().lock().map_err(|_| SurfaceError::Internal)?;
            if views
                .get(&(checked.slot, checked.generation))
                .is_none_or(|view| view.renderer != handle)
            {
                return Err(SurfaceError::StaleKey);
            }
            let (width, height) = session.size();
            let bytes = unsafe { fg_apple_allocation_size(width, height) };
            let lease = session.begin_frame_with_bytes(frame_id, bytes)?;
            (width, height, lease)
        };
        let context = Box::into_raw(Box::new(Allocation {
            key: checked,
            lease,
        }))
        .cast();
        LIVE.fetch_add(1, Ordering::AcqRel);
        let pixels = unsafe { fg_apple_buffer_create(width, height, context, released) };
        if pixels.is_null() {
            released(context);
            return Err(SurfaceError::Internal);
        }
        let buffer = Buffer(pixels);
        let texture = unsafe {
            Retained::from_raw(fg_apple_buffer_texture(
                pixels,
                Retained::as_ptr(&device).cast_mut().cast(),
            ))
        }
        .ok_or(SurfaceError::Internal)?;
        let before = renderer.counters().readback_bytes;
        // SAFETY: this fresh buffer has no consumer and is owned until submission
        // completes. Failed producer resources remain owned by renderer retirement.
        if unsafe { renderer.render_to_metal(&frame, texture) }.is_err() {
            registry()
                .lock()
                .map_err(|_| SurfaceError::Internal)?
                .get_mut(checked)?
                .close()?;
            return Err(SurfaceError::Internal);
        }
        let readback_bytes = renderer.counters().readback_bytes - before;
        let (old, receipt) = {
            let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
            let session = registry.get_mut(checked)?;
            if !session.gpu_completed(lease)? {
                return Err(SurfaceError::FrameSuperseded);
            }
            let mut views = attachments().lock().map_err(|_| SurfaceError::Internal)?;
            let view = views
                .get_mut(&(checked.slot, checked.generation))
                .ok_or(SurfaceError::Closed)?;
            view.epoch = epoch;
            let old = view.published.replace(buffer);
            let receipt = Fg2FrameReceipt {
                epoch,
                frame_id,
                resident_bytes: session.resident_bytes(),
                readback_bytes,
                ..Default::default()
            };
            (old, receipt)
        };
        // Pixel-buffer destruction can call the lease registry synchronously.
        drop(old);
        PRESENTED.fetch_add(1, Ordering::AcqRel);
        READBACK.fetch_add(readback_bytes, Ordering::AcqRel);
        Ok(receipt)
    }
    pub(super) fn copy_buffer(key: Fg2SurfaceKey) -> *mut c_void {
        let Ok(checked) = key.checked() else {
            return std::ptr::null_mut();
        };
        let Ok(mut registry) = registry().lock() else {
            return std::ptr::null_mut();
        };
        let Ok(session) = registry.get_mut(checked) else {
            return std::ptr::null_mut();
        };
        if session.state() != SurfaceState::Ready {
            return std::ptr::null_mut();
        }
        let Ok(views) = attachments().lock() else {
            return std::ptr::null_mut();
        };
        let Some(view) = views.get(&(checked.slot, checked.generation)) else {
            return std::ptr::null_mut();
        };
        if view.epoch != session.epoch() {
            return std::ptr::null_mut();
        }
        let Some(buffer) = &view.published else {
            return std::ptr::null_mut();
        };
        unsafe { fg_apple_buffer_retain(buffer.0) };
        buffer.0
    }
    pub(super) unsafe fn release_buffer(buffer: *mut c_void) {
        unsafe { fg_apple_buffer_release(buffer) }
    }
    pub(super) fn detach(key: Fg2SurfaceKey) {
        let Ok(checked) = key.checked() else {
            return;
        };
        let old = attachments()
            .lock()
            .ok()
            .and_then(|mut views| views.remove(&(checked.slot, checked.generation)));
        drop(old);
    }
    pub(super) fn close_renderer(handle: u64) {
        let keys: Vec<_> = attachments()
            .lock()
            .map(|views| {
                views
                    .iter()
                    .filter(|(_, view)| view.renderer == handle)
                    .map(|(key, _)| *key)
                    .collect()
            })
            .unwrap_or_default();
        for (slot, generation) in keys {
            let key = SurfaceKey { slot, generation };
            if let Ok(mut registry) = registry().lock()
                && let Ok(session) = registry.get_mut(key)
            {
                let _ = session.close();
            }
            let old = attachments()
                .lock()
                .ok()
                .and_then(|mut views| views.remove(&(slot, generation)));
            drop(old);
        }
    }
}

#[cfg(not(target_vendor = "apple"))]
mod platform {
    use super::*;
    pub(super) fn live_buffers() -> u64 {
        0
    }
    pub(super) fn presented_frames() -> u64 {
        0
    }
    pub(super) fn readback_bytes() -> u64 {
        0
    }
    pub(super) fn attach(_: u64, _: Fg2SurfaceKey) -> Result<Fg2SurfaceSnapshot, SurfaceError> {
        Err(SurfaceError::NotReady)
    }
    pub(super) fn render(
        _: u64,
        _: Fg2SurfaceKey,
        _: u64,
        _: u64,
        _: &[u8],
    ) -> Result<Fg2FrameReceipt, SurfaceError> {
        Err(SurfaceError::NotReady)
    }
    pub(super) fn copy_buffer(_: Fg2SurfaceKey) -> *mut c_void {
        std::ptr::null_mut()
    }
    pub(super) unsafe fn release_buffer(_: *mut c_void) {}
    pub(super) fn detach(_: Fg2SurfaceKey) {}
    pub(super) fn close_renderer(_: u64) {}
}
