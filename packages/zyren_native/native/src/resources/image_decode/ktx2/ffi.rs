use super::super::ffi::ImageLimits;
use super::{DecodeError, DecodeLimits, transcode};

#[repr(C)]
pub struct TextureBytes {
    pub data: *mut u8,
    pub length: usize,
}
impl Default for TextureBytes {
    fn default() -> Self {
        Self {
            data: std::ptr::null_mut(),
            length: 0,
        }
    }
}

/// # Safety
/// Input/limits are readable. Output is writable empty storage disjoint from
/// both. A successful packet is owned until one call to `fg2_ktx2_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_ktx2_decode(
    input: *const u8,
    length: usize,
    limits: *const ImageLimits,
    output: *mut TextureBytes,
) -> u32 {
    unsafe { fg2_ktx2_transcode(input, length, limits, 0, output) }
}

/// # Safety
/// Same pointer ownership contract as `fg2_ktx2_decode`. Target is 0..3.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_ktx2_transcode(
    input: *const u8,
    length: usize,
    limits: *const ImageLimits,
    target: u32,
    output: *mut TextureBytes,
) -> u32 {
    if output.is_null() {
        return DecodeError::InvalidData as u32;
    }
    unsafe {
        *output = TextureBytes::default();
    }
    let result = std::panic::catch_unwind(|| {
        if input.is_null() || limits.is_null() || length == 0 {
            return Err(DecodeError::InvalidData);
        }
        if length > 16 * 1024 * 1024 {
            return Err(DecodeError::LimitExceeded);
        }
        let limits = unsafe { &*limits };
        if limits.version != 1 {
            return Err(DecodeError::InvalidLimits);
        }
        let data = transcode(
            unsafe { std::slice::from_raw_parts(input, length) },
            DecodeLimits {
                max_encoded_bytes: limits.max_encoded_bytes,
                max_decoded_bytes: limits.max_decoded_bytes,
                max_working_bytes: limits.max_working_bytes,
                max_dimension: limits.max_dimension,
            },
            target,
        )?
        .into_boxed_slice();
        unsafe {
            *output = TextureBytes {
                length: data.len(),
                data: Box::into_raw(data).cast::<u8>(),
            };
        }
        Ok(())
    });
    match result {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => error as u32,
        Err(_) => DecodeError::Internal as u32,
    }
}

/// # Safety
/// Output is the unchanged result of decode, or an already cleared descriptor.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_ktx2_free(output: *mut TextureBytes) {
    if output.is_null() {
        return;
    }
    let output = unsafe { &mut *output };
    if !output.data.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                output.data,
                output.length,
            )));
        }
    }
    *output = TextureBytes::default();
}
