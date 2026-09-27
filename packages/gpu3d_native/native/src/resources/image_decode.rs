use image::{ColorType, ImageDecoder, ImageError, Limits, codecs::png::PngDecoder};
use std::{
    io::Cursor,
    sync::atomic::{AtomicU64, Ordering},
};
pub mod ffi;
mod jpeg;

const MIB: u64 = 1024 * 1024;
static BUDGET: Budget = Budget::new(256 * MIB);

#[derive(Clone, Copy, Debug)]
pub struct DecodeLimits {
    pub max_encoded_bytes: u64,
    pub max_decoded_bytes: u64,
    pub max_working_bytes: u64,
    pub max_dimension: u32,
}
impl Default for DecodeLimits {
    fn default() -> Self {
        Self {
            max_encoded_bytes: 16 * MIB,
            max_decoded_bytes: 64 * MIB,
            max_working_bytes: 128 * MIB,
            max_dimension: 4096,
        }
    }
}
impl DecodeLimits {
    pub fn validate(self) -> Result<(), DecodeError> {
        if self.max_encoded_bytes == 0
            || self.max_encoded_bytes > 16 * MIB
            || self.max_decoded_bytes == 0
            || self.max_decoded_bytes > 64 * MIB
            || self.max_working_bytes == 0
            || self.max_working_bytes > 128 * MIB
            || self.max_dimension == 0
            || self.max_dimension > 4096
        {
            return Err(DecodeError::InvalidLimits);
        }
        Ok(())
    }
    fn decoder_limits(self, bytes: u64) -> Limits {
        let mut limits = Limits::default();
        limits.max_image_width = Some(self.max_dimension);
        limits.max_image_height = Some(self.max_dimension);
        limits.max_alloc = Some(bytes);
        limits
    }
}
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
#[repr(u32)]
pub enum DecodeError {
    InvalidData = 1,
    UnsupportedFormat = 2,
    UnsupportedColor = 3,
    LimitExceeded = 4,
    Busy = 5,
    Internal = 6,
    InvalidLimits = 7,
}
impl From<ImageError> for DecodeError {
    fn from(error: ImageError) -> Self {
        match error {
            ImageError::Limits(_) => Self::LimitExceeded,
            ImageError::Unsupported(_) => Self::UnsupportedColor,
            _ => Self::InvalidData,
        }
    }
}
#[derive(Debug)]
pub struct DecodedImage {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

struct Budget {
    used: AtomicU64,
    capacity: u64,
}
struct Reservation<'a> {
    budget: &'a Budget,
    bytes: u64,
}
impl Budget {
    const fn new(capacity: u64) -> Self {
        Self {
            used: AtomicU64::new(0),
            capacity,
        }
    }
    fn reserve(&self, bytes: u64) -> Result<Reservation<'_>, DecodeError> {
        self.used
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
                used.checked_add(bytes)
                    .filter(|total| *total <= self.capacity)
            })
            .map_err(|_| DecodeError::Busy)?;
        Ok(Reservation {
            budget: self,
            bytes,
        })
    }
}
impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        self.budget.used.fetch_sub(self.bytes, Ordering::AcqRel);
    }
}

fn png_complete(bytes: &[u8]) -> Result<(), DecodeError> {
    let mut offset = 8_usize;
    while offset < bytes.len() {
        let header = bytes
            .get(offset..offset + 8)
            .ok_or(DecodeError::InvalidData)?;
        let length = u32::from_be_bytes(header[..4].try_into().unwrap()) as usize;
        let end = offset
            .checked_add(12)
            .and_then(|x| x.checked_add(length))
            .filter(|end| *end <= bytes.len())
            .ok_or(DecodeError::InvalidData)?;
        let expected_crc = u32::from_be_bytes(bytes[end - 4..end].try_into().unwrap());
        if crc32fast::hash(&bytes[offset + 4..end - 4]) != expected_crc {
            return Err(DecodeError::InvalidData);
        }
        if &header[4..] == b"acTL" {
            return Err(DecodeError::UnsupportedFormat);
        }
        if &header[4..] == b"IEND" {
            return if length == 0 && end == bytes.len() {
                Ok(())
            } else {
                Err(DecodeError::InvalidData)
            };
        }
        offset = end;
    }
    Err(DecodeError::InvalidData)
}

pub fn decode(bytes: &[u8], limits: DecodeLimits) -> Result<DecodedImage, DecodeError> {
    limits.validate()?;
    if bytes.is_empty() {
        return Err(DecodeError::InvalidData);
    }
    if bytes.len() as u64 > limits.max_encoded_bytes {
        return Err(DecodeError::LimitExceeded);
    }
    let _reservation = BUDGET.reserve(limits.max_working_bytes)?;
    // Account for the borrowed stream and metadata copies before constructing
    // a decoder. Dart transfer/copy overhead is outside this native reservation.
    let available = limits
        .max_working_bytes
        .checked_sub(bytes.len() as u64 * 2)
        .ok_or(DecodeError::LimitExceeded)?;
    let mut decoder: Box<dyn ImageDecoder> = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        png_complete(bytes)?;
        Box::new(PngDecoder::with_limits(
            Cursor::new(bytes),
            limits.decoder_limits(available),
        )?)
    } else if bytes.starts_with(&[0xff, 0xd8]) {
        return decode_jpeg(bytes, limits, available);
    } else {
        return Err(DecodeError::UnsupportedFormat);
    };
    let (width, height) = decoder.dimensions();
    if width == 0 || height == 0 || width > limits.max_dimension || height > limits.max_dimension {
        return Err(DecodeError::LimitExceeded);
    }
    let color = decoder.color_type();
    let channels = match color {
        ColorType::L8 => 1,
        ColorType::La8 => 2,
        ColorType::Rgb8 => 3,
        ColorType::Rgba8 => 4,
        _ => return Err(DecodeError::UnsupportedColor),
    };
    let output = u64::from(width)
        .checked_mul(u64::from(height))
        .and_then(|n| n.checked_mul(4))
        .filter(|n| *n <= limits.max_decoded_bytes)
        .ok_or(DecodeError::LimitExceeded)?;
    let raw_bytes = decoder.total_bytes();
    let conversion_bytes = if channels == 4 { 0 } else { output };
    let decoder_budget = available
        .checked_sub(conversion_bytes)
        .ok_or(DecodeError::LimitExceeded)?;
    if raw_bytes > decoder_budget {
        return Err(DecodeError::LimitExceeded);
    }
    decoder.set_limits(limits.decoder_limits(decoder_budget))?;
    let mut raw = Vec::new();
    raw.try_reserve_exact(raw_bytes as usize)
        .map_err(|_| DecodeError::LimitExceeded)?;
    raw.resize(raw_bytes as usize, 0);
    decoder.read_image(&mut raw)?;
    let pixels = if channels == 4 {
        raw
    } else {
        let mut rgba = Vec::new();
        rgba.try_reserve_exact(output as usize)
            .map_err(|_| DecodeError::LimitExceeded)?;
        for pixel in raw.chunks_exact(channels) {
            match channels {
                1 => rgba.extend_from_slice(&[pixel[0], pixel[0], pixel[0], 255]),
                2 => rgba.extend_from_slice(&[pixel[0], pixel[0], pixel[0], pixel[1]]),
                _ => rgba.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]),
            }
        }
        rgba
    };
    Ok(DecodedImage {
        width,
        height,
        pixels,
    })
}

fn decode_jpeg(
    bytes: &[u8],
    limits: DecodeLimits,
    available: u64,
) -> Result<DecodedImage, DecodeError> {
    use zune_core::{bytestream::ZCursor, colorspace::ColorSpace, options::DecoderOptions};
    use zune_jpeg::{JpegDecoder, errors::DecodeErrors};
    fn error(error: DecodeErrors) -> DecodeError {
        match error {
            DecodeErrors::LargeDimensions(_) => DecodeError::LimitExceeded,
            DecodeErrors::Unsupported(_) => DecodeError::UnsupportedFormat,
            _ => DecodeError::InvalidData,
        }
    }
    jpeg::validate(bytes, limits)?;
    // Headers may retain metadata. Reserve fixed table/header space before
    // allowing the decoder to inspect dimensions or allocate scan buffers.
    if available < MIB {
        return Err(DecodeError::LimitExceeded);
    }
    let options = DecoderOptions::default()
        .set_strict_mode(true)
        .set_max_width(limits.max_dimension as usize)
        .set_max_height(limits.max_dimension as usize)
        .jpeg_set_max_scans(64)
        .jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut decoder = JpegDecoder::new_with_options(ZCursor::new(bytes), options);
    decoder.decode_headers().map_err(error)?;
    let (width, height) = decoder.dimensions().ok_or(DecodeError::InvalidData)?;
    let output = (width as u64)
        .checked_mul(height as u64)
        .and_then(|n| n.checked_mul(4))
        .filter(|n| *n <= limits.max_decoded_bytes)
        .ok_or(DecodeError::LimitExceeded)?;
    // zune-jpeg 0.5.15 has no allocator budget. Its full-frame i16 coefficient
    // arrays use at most four components over the MCU-padded extent. Allow
    // 8192 bytes per padded column for row/upsampling buffers (sampling <= 4),
    // plus 1 MiB for tables. Re-audit these estimates when changing the pin.
    // This is conservative admission accounting, not a process RSS limit.
    let padded_width = (width as u64).div_ceil(32) * 32;
    let padded_height = (height as u64).div_ceil(32) * 32;
    let scratch = padded_width
        .checked_mul(padded_height)
        .and_then(|n| n.checked_mul(8))
        .and_then(|n| n.checked_add(padded_width * 8192 + MIB))
        .ok_or(DecodeError::LimitExceeded)?;
    if output.checked_add(scratch).is_none_or(|n| n > available) {
        return Err(DecodeError::LimitExceeded);
    }
    if decoder.output_buffer_size() != Some(output as usize) {
        return Err(DecodeError::UnsupportedColor);
    }
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(output as usize)
        .map_err(|_| DecodeError::LimitExceeded)?;
    pixels.resize(output as usize, 0);
    decoder.decode_into(&mut pixels).map_err(error)?;
    Ok(DecodedImage {
        width: width as u32,
        height: height as u32,
        pixels,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reservations_reject_overcommit_and_release_on_drop() {
        let budget = Budget::new(16);
        let first = budget.reserve(12).unwrap();
        assert!(matches!(budget.reserve(8), Err(DecodeError::Busy)));
        drop(first);
        assert!(budget.reserve(16).is_ok());
        assert_eq!(budget.used.load(Ordering::Acquire), 0);
    }
}
