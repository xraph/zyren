pub mod geometry_update;
pub mod interop;
pub mod lighting;
pub mod render_graph;
pub mod renderer;
pub mod resources;
mod retirement;
pub mod scene;
pub mod scene_packet;
pub mod shaders;
pub mod shadows;
pub mod tangents;

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
    interop::apple::close_renderer_surfaces(handle);
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
        let mut renderer = renderer
            .lock()
            .map_err(|_| "renderer is poisoned; recreate it")?;
        let frame = renderer.decode_scene(unsafe { std::slice::from_raw_parts(json, json_len) })?;
        let image = renderer.render(&frame, width, height)?;
        unsafe {
            std::ptr::copy_nonoverlapping(image.as_ptr(), pixels, len);
        }
        Ok(1)
    })
}

/// Executes a bounded little-endian resource command on the renderer's device.
///
/// # Safety
/// Input and output buffers must be valid for their supplied lengths. `written`
/// must point to writable storage. The buffers must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_resource_command(
    handle: u64,
    input: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> u32 {
    let mut code = resources::ResourceError::InvalidCommand as u32;
    let ok: u32 = guard(|| {
        if input.is_null()
            || output.is_null()
            || written.is_null()
            || length > resources::upload::MAX_COMMAND_BYTES
            || capacity > resources::upload::MAX_BYTES as usize + 24
        {
            return Err("invalid resource command buffers".into());
        }
        // SAFETY: the caller guarantees valid buffers; lengths are bounded above.
        unsafe {
            *written = 0;
        }
        let renderer = registry()
            .lock()
            .map_err(|_| "registry lock failed")?
            .get(&handle)
            .cloned()
            .ok_or("renderer disposed")?;
        let bytes = unsafe { std::slice::from_raw_parts(input, length) };
        let result = renderer
            .lock()
            .map_err(|_| "renderer lock failed")?
            .resource_command(bytes, capacity)
            .map_err(|error| {
                code = error as u32;
                error.to_string()
            })?;
        unsafe {
            std::ptr::copy_nonoverlapping(result.as_ptr(), output, result.len());
            *written = result.len();
        }
        Ok(1)
    });
    if ok == 1 { 0 } else { code }
}

#[unsafe(no_mangle)]
pub extern "C" fn fg2_scene_close(handle: u64, view: u64) -> u32 {
    guard(|| {
        let renderer = registry()
            .lock()
            .map_err(|_| "registry lock failed")?
            .get(&handle)
            .cloned()
            .ok_or("renderer disposed")?;
        renderer
            .lock()
            .map_err(|_| "renderer lock failed")?
            .close_scene_view(view)?;
        Ok(1)
    })
}

/// Executes a bounded JSON shader command. Returns zero for a response, including
/// compiler diagnostics, or one for a transport error available in fg_last_error.
/// # Safety
/// Input and output buffers must be valid for their supplied lengths. `written`
/// must point to writable storage. The buffers must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_shader_command(
    handle: u64,
    input: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> u32 {
    let ok: u32 = guard(|| {
        if written.is_null() {
            return Err("Missing shader response length".into());
        }
        unsafe {
            *written = 0;
        }
        if input.is_null()
            || output.is_null()
            || length == 0
            || length > shaders::MAX_COMMAND_BYTES
            || capacity != shaders::RESPONSE_CAPACITY
        {
            return Err("Invalid shader command buffers".into());
        }
        let renderer = registry()
            .lock()
            .map_err(|_| "Registry lock failed")?
            .get(&handle)
            .cloned()
            .ok_or("Renderer disposed")?;
        let bytes = unsafe { std::slice::from_raw_parts(input, length) };
        let result = renderer
            .lock()
            .map_err(|_| "Renderer lock failed")?
            .shader_command(bytes, capacity)?;
        unsafe {
            std::ptr::copy_nonoverlapping(result.as_ptr(), output, result.len());
            *written = result.len();
        }
        Ok(1)
    });
    if ok == 1 { 0 } else { 1 }
}
/// Executes a bounded JSON graph command. Returns zero for a response, including
/// graph diagnostics, or one for a transport error available in fg_last_error.
/// # Safety
/// Input and output buffers must be valid for their supplied lengths. `written`
/// must point to writable storage. The buffers must not overlap.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_graph_command(
    handle: u64,
    input: *const u8,
    length: usize,
    output: *mut u8,
    capacity: usize,
    written: *mut usize,
) -> u32 {
    let ok: u32 = guard(|| {
        if written.is_null() {
            return Err("Missing graph response length".into());
        }
        unsafe {
            *written = 0;
        }
        if input.is_null()
            || output.is_null()
            || length == 0
            || length > render_graph::MAX_COMMAND_BYTES
            || capacity != render_graph::RESPONSE_CAPACITY
        {
            return Err("Invalid graph command buffers".into());
        }
        let renderer = registry()
            .lock()
            .map_err(|_| "Registry lock failed")?
            .get(&handle)
            .cloned()
            .ok_or("Renderer disposed")?;
        let bytes = unsafe { std::slice::from_raw_parts(input, length) };
        let result = renderer
            .lock()
            .map_err(|_| "Renderer lock failed")?
            .graph_command(bytes, capacity)?;
        unsafe {
            std::ptr::copy_nonoverlapping(result.as_ptr(), output, result.len());
            *written = result.len();
        }
        Ok(1)
    });
    if ok == 1 { 0 } else { 1 }
}
#[unsafe(no_mangle)]
pub extern "C" fn fg2_scene_resident_bytes(handle: u64) -> u64 {
    guard(|| {
        let renderer = registry()
            .lock()
            .map_err(|_| "registry lock failed")?
            .get(&handle)
            .cloned()
            .ok_or("renderer disposed")?;
        Ok(renderer
            .lock()
            .map_err(|_| "renderer lock failed")?
            .scene_resource_stats()
            .0)
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn fg2_scene_uploaded_bytes(handle: u64) -> u64 {
    guard(|| {
        let renderer = registry()
            .lock()
            .map_err(|_| "registry lock failed")?
            .get(&handle)
            .cloned()
            .ok_or("renderer disposed")?;
        Ok(renderer
            .lock()
            .map_err(|_| "renderer lock failed")?
            .scene_resource_stats()
            .1)
    })
}
