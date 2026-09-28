use super::{DecodeError, DecodeLimits, decode};

#[repr(C)]
pub struct ImageLimits {
    pub version: u32,
    pub max_dimension: u32,
    pub max_encoded_bytes: u64,
    pub max_decoded_bytes: u64,
    pub max_working_bytes: u64,
}
impl Default for ImageLimits {
    fn default() -> Self {
        let limits = DecodeLimits::default();
        Self {
            version: 1,
            max_dimension: limits.max_dimension,
            max_encoded_bytes: limits.max_encoded_bytes,
            max_decoded_bytes: limits.max_decoded_bytes,
            max_working_bytes: limits.max_working_bytes,
        }
    }
}
#[repr(C)]
pub struct ImagePixels {
    pub width: u32,
    pub height: u32,
    pub pixels: *mut u8,
    pub length: usize,
}
impl Default for ImagePixels {
    fn default() -> Self {
        Self {
            width: 0,
            height: 0,
            pixels: std::ptr::null_mut(),
            length: 0,
        }
    }
}

/// Decode CPU pixels. No renderer handle or GPU is required.
/// # Safety
/// Input and limits must be readable for their stated lengths. Output must be
/// writable, empty storage, disjoint from input and limits. On success the
/// caller owns its pixels until exactly one call to `fg2_image_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_image_decode(
    input: *const u8,
    length: usize,
    limits: *const ImageLimits,
    output: *mut ImagePixels,
) -> u32 {
    if output.is_null() {
        return DecodeError::InvalidData as u32;
    }
    unsafe {
        *output = ImagePixels::default();
    }
    let mut code = DecodeError::Internal;
    let ok: u32 = crate::guard(|| {
        if input.is_null() || limits.is_null() || length == 0 || length > 16 * 1024 * 1024 {
            code = DecodeError::InvalidData;
            return Err("invalid image input buffers".into());
        }
        let limits = unsafe { &*limits };
        if limits.version != 1 {
            code = DecodeError::InvalidLimits;
            return Err("unsupported image limits version".into());
        }
        let limits = DecodeLimits {
            max_dimension: limits.max_dimension,
            max_encoded_bytes: limits.max_encoded_bytes,
            max_decoded_bytes: limits.max_decoded_bytes,
            max_working_bytes: limits.max_working_bytes,
        };
        let image = decode(unsafe { std::slice::from_raw_parts(input, length) }, limits).map_err(
            |error| {
                code = error;
                format!("image decode: {error:?}")
            },
        )?;
        let pixels = image.pixels.into_boxed_slice();
        unsafe {
            *output = ImagePixels {
                width: image.width,
                height: image.height,
                length: pixels.len(),
                pixels: Box::into_raw(pixels).cast::<u8>(),
            };
        }
        Ok(1)
    });
    if ok == 1 { 0 } else { code as u32 }
}

/// Release returned native pixels and clear the descriptor.
/// # Safety
/// A non-null output must point to the unchanged result of `fg2_image_decode`,
/// or to a descriptor already cleared by this function. Do not copy ownership.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_image_free(output: *mut ImagePixels) {
    if output.is_null() {
        return;
    }
    let image = unsafe { std::mem::take(&mut *output) };
    if !image.pixels.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                image.pixels,
                image.length,
            )));
        }
    }
}
