use super::{DecodeError, DecodeLimits, MIB};

// Reserve owned pixels before constructing the pinned png 0.18.1 reader.
// image 0.25.10's set_limits does not update that reader after construction.
pub(super) fn decoder_budget(
    bytes: &[u8],
    limits: DecodeLimits,
    available: u64,
) -> Result<u64, DecodeError> {
    let header = bytes.get(8..33).ok_or(DecodeError::InvalidData)?;
    if header[..4] != 13u32.to_be_bytes() || &header[4..8] != b"IHDR" {
        return Err(DecodeError::InvalidData);
    }
    let width = u32::from_be_bytes(header[8..12].try_into().unwrap());
    let height = u32::from_be_bytes(header[12..16].try_into().unwrap());
    if width == 0 || height == 0 || width > limits.max_dimension || height > limits.max_dimension {
        return Err(DecodeError::LimitExceeded);
    }
    if header[16] > 8 {
        return Err(DecodeError::UnsupportedColor);
    }
    // RGB/palette may expand to RGB or RGBA with tRNS. Grayscale may expand
    // to LA. Account for simultaneous source and converted RGBA allocations.
    let owned_channels = match header[17] {
        6 => 4,
        2 | 3 => 7,
        0 | 4 => 6,
        _ => return Err(DecodeError::UnsupportedColor),
    };
    let pixels = u64::from(width) * u64::from(height);
    if pixels
        .checked_mul(4)
        .is_none_or(|n| n > limits.max_decoded_bytes)
    {
        return Err(DecodeError::LimitExceeded);
    }
    let remaining = pixels
        .checked_mul(owned_channels)
        .and_then(|owned| available.checked_sub(owned))
        .ok_or(DecodeError::LimitExceeded)?;
    // Admission floor for inflate state, tables and row/filter/transform
    // buffers. Metadata allocations also use the reader's remaining limit.
    // This excludes allocator overhead and is not a process RSS guarantee.
    let workspace = MIB + u64::from(width) * 32;
    if remaining < workspace {
        return Err(DecodeError::LimitExceeded);
    }
    Ok(remaining)
}
