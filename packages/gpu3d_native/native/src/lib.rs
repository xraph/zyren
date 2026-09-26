pub mod interop;
pub mod renderer;
mod retirement;
pub mod scene;

use std::{
    cell::RefCell,
    collections::HashMap,
    panic::AssertUnwindSafe,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
};

use renderer::Renderer;

type Renderers = HashMap<u64, Arc<Mutex<Renderer>>>;
static RENDERERS: OnceLock<Mutex<Renderers>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
thread_local! { static ERROR: RefCell<String> = const { RefCell::new(String::new()) }; }

fn registry() -> &'static Mutex<Renderers> {
    RENDERERS.get_or_init(Mutex::default)
}

fn guard<T: Default>(operation: impl FnOnce() -> Result<T, String>) -> T {
    ERROR.with(|e| e.borrow_mut().clear());
    match std::panic::catch_unwind(AssertUnwindSafe(operation)) {
        Ok(Ok(value)) => value,
        result => {
            let message = match result {
                Ok(Err(error)) => error,
                _ => "native renderer panicked; dispose and recreate it".into(),
            };
            ERROR.with(|e| *e.borrow_mut() = message);
            T::default()
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn fg_abi_version() -> u32 {
    1
}

/// Process-local diagnostic for verifying handle cleanup.
#[unsafe(no_mangle)]
pub extern "C" fn fg_live_renderer_count() -> usize {
    guard(|| {
        Ok(registry()
            .lock()
            .map_err(|_| "renderer registry is poisoned")?
            .len())
    })
}

/// GPU sessions whose native ownership outlives logical disposal.
#[unsafe(no_mangle)]
pub extern "C" fn fg_retiring_renderer_count() -> usize {
    retirement::retiring_count()
}

#[unsafe(no_mangle)]
pub extern "C" fn fg_create() -> u64 {
    guard(|| {
        let renderer = pollster::block_on(Renderer::new())?;
        let id = NEXT_ID
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| {
                id.checked_add(1).filter(|next| *next <= usize::MAX as u64)
            })
            .map_err(|_| "renderer handle space exhausted")?;
        registry()
            .lock()
            .map_err(|_| "renderer registry is poisoned")?
            .insert(id, Arc::new(Mutex::new(renderer)));
        Ok(id)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn fg_destroy(handle: u64) -> u32 {
    guard(|| {
        let removed = registry()
            .lock()
            .map_err(|_| "renderer registry is poisoned")?
            .remove(&handle);
        removed.ok_or("invalid or disposed renderer handle")?;
        Ok(1)
    })
}

/// NativeFinalizer callback. The token is an opaque integer, never dereferenced.
#[unsafe(no_mangle)]
pub extern "C" fn fg_finalize(token: *mut std::ffi::c_void) {
    fg_destroy(token as usize as u64);
}

/// Returns the UTF-8 error length, excluding a terminator. Truncates to capacity.
/// # Safety
/// A non-null buffer must refer to at least `capacity` writable bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_last_error(buffer: *mut u8, capacity: usize) -> usize {
    ERROR.with(|error| {
        let error = error.borrow();
        if !buffer.is_null() && capacity > 0 {
            unsafe {
                std::ptr::copy_nonoverlapping(error.as_ptr(), buffer, error.len().min(capacity));
            }
        }
        error.len()
    })
}

/// # Safety
/// `json` must contain `json_len` readable bytes, and `pixels` must point to
/// `capacity` writable bytes. The two buffers must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg_render(
    handle: u64,
    json: *const u8,
    json_len: usize,
    width: u32,
    height: u32,
    pixels: *mut u8,
    capacity: usize,
) -> u32 {
    guard(|| {
        let len = scene::pixel_len(width, height)?;
        if json.is_null()
            || pixels.is_null()
            || json_len == 0
            || json_len > 128 * 1024 * 1024
            || capacity < len
        {
            return Err("invalid input or output buffer".into());
        }
        let renderer = registry()
            .lock()
            .map_err(|_| "renderer registry is poisoned")?
            .get(&handle)
            .cloned()
            .ok_or("invalid or disposed renderer handle")?;
        let frame: scene::Frame =
            serde_json::from_slice(unsafe { std::slice::from_raw_parts(json, json_len) })
                .map_err(|e| format!("invalid scene: {e}"))?;
        let mut renderer = renderer
            .lock()
            .map_err(|_| "renderer is poisoned; recreate it")?;
        let image = renderer.render(&frame, width, height)?;
        unsafe {
            std::ptr::copy_nonoverlapping(image.as_ptr(), pixels, len);
        }
        Ok(1)
    })
}
