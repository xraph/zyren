use super::{
    SurfaceConfig, SurfaceError, SurfaceKey, SurfaceRegistry, SurfaceSession, SurfaceState,
};
use std::{
    hash::{Hash, Hasher},
    mem::size_of,
    panic::AssertUnwindSafe,
    sync::{Mutex, OnceLock},
};

const VERSION: u32 = 2;
static RUNTIME: OnceLock<u64> = OnceLock::new();
pub(crate) static SURFACES: OnceLock<Mutex<SurfaceRegistry>> = OnceLock::new();
pub(crate) fn registry() -> &'static Mutex<SurfaceRegistry> {
    SURFACES.get_or_init(Mutex::default)
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Fg2SurfaceKey {
    pub struct_size: u32,
    pub abi_version: u32,
    pub runtime_token: u64,
    pub slot: u64,
    pub generation: u64,
}
impl Fg2SurfaceKey {
    pub(crate) fn checked(self) -> Result<SurfaceKey, SurfaceError> {
        if self.struct_size != size_of::<Self>() as u32 || self.abi_version != VERSION {
            return Err(SurfaceError::InvalidArgument);
        }
        if self.runtime_token != fg2_runtime_token() {
            return Err(SurfaceError::StaleKey);
        }
        Ok(SurfaceKey {
            slot: self.slot,
            generation: self.generation,
        })
    }
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Fg2SurfaceDescriptor {
    pub struct_size: u32,
    pub abi_version: u32,
    pub width: u32,
    pub height: u32,
    pub buffer_limit: u32,
    pub max_in_flight: u32,
    pub memory_limit: u64,
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Fg2SurfaceSnapshot {
    pub struct_size: u32,
    pub abi_version: u32,
    pub key: Fg2SurfaceKey,
    pub epoch: u64,
    pub width: u32,
    pub height: u32,
    pub state: u32,
    pub reserved: u32,
}
impl Default for Fg2SurfaceSnapshot {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            abi_version: VERSION,
            key: Fg2SurfaceKey::default(),
            epoch: 0,
            width: 0,
            height: 0,
            state: 0,
            reserved: 0,
        }
    }
}
#[repr(C)]
pub struct Fg2Error {
    pub struct_size: u32,
    pub abi_version: u32,
    pub code: u32,
    pub message_length: u32,
    pub message: [u8; 240],
}
impl Default for Fg2Error {
    fn default() -> Self {
        Self {
            struct_size: size_of::<Self>() as u32,
            abi_version: VERSION,
            code: 0,
            message_length: 0,
            message: [0; 240],
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy)]
struct Header {
    size: u32,
    version: u32,
}
unsafe fn valid<T>(pointer: *const T) -> bool {
    if pointer.is_null() {
        return false;
    }
    // SAFETY: callers provide at least the common eight-byte record header.
    let header = unsafe { pointer.cast::<Header>().read_unaligned() };
    header.size == size_of::<T>() as u32 && header.version == VERSION
}
pub(crate) fn snapshot(key: SurfaceKey, session: &SurfaceSession) -> Fg2SurfaceSnapshot {
    let (width, height) = session.size();
    Fg2SurfaceSnapshot {
        key: Fg2SurfaceKey {
            struct_size: size_of::<Fg2SurfaceKey>() as u32,
            abi_version: VERSION,
            runtime_token: fg2_runtime_token(),
            slot: key.slot,
            generation: key.generation,
        },
        epoch: session.epoch(),
        width,
        height,
        state: match session.state() {
            SurfaceState::Creating => 0,
            SurfaceState::Ready => 1,
            SurfaceState::Suspended => 2,
            SurfaceState::Closing => 3,
            SurfaceState::Closed => 4,
        },
        ..Default::default()
    }
}
pub(crate) unsafe fn call<T>(
    output: *mut T,
    error: *mut Fg2Error,
    operation: impl FnOnce() -> Result<T, SurfaceError>,
) -> u32 {
    // SAFETY: each exported entry point documents the caller's buffer capacities.
    if !unsafe { valid(error) } {
        return SurfaceError::InvalidArgument as u32;
    }
    let result = if unsafe { valid(output) } {
        std::panic::catch_unwind(AssertUnwindSafe(operation)).unwrap_or(Err(SurfaceError::Internal))
    } else {
        Err(SurfaceError::InvalidArgument)
    };
    let mut issue = Fg2Error::default();
    match result {
        Ok(value) => {
            unsafe {
                output.write_unaligned(value);
                error.write_unaligned(issue);
            }
            0
        }
        Err(failure) => {
            issue.code = failure as u32;
            let message = failure.to_string();
            let bytes = message.as_bytes();
            let length = bytes.len().min(issue.message.len());
            issue.message[..length].copy_from_slice(&bytes[..length]);
            issue.message_length = length as u32;
            unsafe {
                error.write_unaligned(issue);
            }
            failure as u32
        }
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn fg2_runtime_token() -> u64 {
    *RUNTIME.get_or_init(|| {
        let mut hash = std::collections::hash_map::DefaultHasher::new();
        std::time::SystemTime::now().hash(&mut hash);
        std::process::id().hash(&mut hash);
        (&RUNTIME as *const _ as usize).hash(&mut hash);
        hash.finish().max(1)
    })
}
/// # Safety
/// Records must contain at least the common header and the capacity declared in
/// struct_size. Output/error storage is writable and must not alias other records.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_surface_create(
    descriptor: *const Fg2SurfaceDescriptor,
    output: *mut Fg2SurfaceSnapshot,
    error: *mut Fg2Error,
) -> u32 {
    unsafe {
        call(output, error, || {
            if !valid(descriptor) {
                return Err(SurfaceError::InvalidArgument);
            }
            let desc = descriptor.read_unaligned();
            let config = SurfaceConfig {
                width: desc.width,
                height: desc.height,
                buffer_limit: desc.buffer_limit as usize,
                max_in_flight: desc.max_in_flight as usize,
                memory_limit: desc.memory_limit,
            };
            let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
            let key = registry.reserve(config)?;
            Ok(snapshot(key, registry.get_mut(key)?))
        })
    }
}
/// # Safety
/// Output/error records have valid headers and declared writable capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_surface_resize(
    key: Fg2SurfaceKey,
    expected_epoch: u64,
    width: u32,
    height: u32,
    output: *mut Fg2SurfaceSnapshot,
    error: *mut Fg2Error,
) -> u32 {
    unsafe {
        call(output, error, || {
            let key = key.checked()?;
            let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
            let surface = registry.get_mut(key)?;
            if expected_epoch != surface.epoch() {
                return Err(SurfaceError::StaleEpoch);
            }
            surface.resize(width, height)?;
            Ok(snapshot(key, surface))
        })
    }
}
/// # Safety
/// Output/error records have valid headers and declared writable capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_surface_suspend(
    key: Fg2SurfaceKey,
    expected_epoch: u64,
    suspended: u32,
    output: *mut Fg2SurfaceSnapshot,
    error: *mut Fg2Error,
) -> u32 {
    unsafe {
        call(output, error, || {
            if suspended > 1 {
                return Err(SurfaceError::InvalidArgument);
            }
            let key = key.checked()?;
            let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
            let surface = registry.get_mut(key)?;
            if expected_epoch != surface.epoch() {
                return Err(SurfaceError::StaleEpoch);
            }
            if suspended == 1 {
                surface.suspend()?;
            } else {
                surface.resume()?;
            }
            Ok(snapshot(key, surface))
        })
    }
}
/// # Safety
/// Output/error records have valid headers and declared writable capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_surface_close(
    key: Fg2SurfaceKey,
    output: *mut Fg2SurfaceSnapshot,
    error: *mut Fg2Error,
) -> u32 {
    let status = unsafe {
        call(output, error, || {
            let key = key.checked()?;
            let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
            let surface = registry.get_mut(key)?;
            surface.close()?;
            Ok(snapshot(key, surface))
        })
    };
    if status == 0 {
        super::apple::detach(key);
    }
    status
}

/// # Safety
/// Output/error records have valid headers and declared writable capacities.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_surface_snapshot(
    key: Fg2SurfaceKey,
    output: *mut Fg2SurfaceSnapshot,
    error: *mut Fg2Error,
) -> u32 {
    unsafe {
        call(output, error, || {
            let key = key.checked()?;
            let mut registry = registry().lock().map_err(|_| SurfaceError::Internal)?;
            Ok(snapshot(key, registry.get_mut(key)?))
        })
    }
}
