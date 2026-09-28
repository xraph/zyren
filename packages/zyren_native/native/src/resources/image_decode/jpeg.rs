use super::{DecodeError, DecodeLimits};

// Validate marker framing before header parsing. In particular, an EOI marker
// cannot stand in for missing entropy data, even when the decoder recovers it.
pub(super) fn validate(bytes: &[u8], limits: DecodeLimits) -> Result<(), DecodeError> {
    let mut offset = 2;
    let mut frame = false;
    let mut in_scan = false;
    let mut scan_data = false;
    let mut scans = 0;
    while offset < bytes.len() {
        if bytes[offset] != 0xff {
            if !in_scan {
                return Err(DecodeError::InvalidData);
            }
            scan_data = true;
            offset += 1;
            continue;
        }
        while bytes.get(offset) == Some(&0xff) {
            offset += 1;
        }
        let marker = *bytes.get(offset).ok_or(DecodeError::InvalidData)?;
        offset += 1;
        if in_scan && (marker == 0 || (0xd0..=0xd7).contains(&marker)) {
            scan_data |= marker == 0;
            continue;
        }
        if in_scan && !scan_data {
            return Err(DecodeError::InvalidData);
        }
        in_scan = false;
        if marker == 0xd9 {
            // Embedded Google tile textures can include zero alignment bytes.
            // Accept at most a four-byte alignment tail, never another payload.
            let tail = &bytes[offset..];
            return if scans > 0 && tail.len() <= 3 && tail.iter().all(|byte| *byte == 0) {
                Ok(())
            } else {
                Err(DecodeError::InvalidData)
            };
        }
        if matches!(marker, 0 | 1 | 0xd0..=0xd8) {
            return Err(DecodeError::InvalidData);
        }
        let header = bytes
            .get(offset..offset + 2)
            .ok_or(DecodeError::InvalidData)?;
        let length = u16::from_be_bytes(header.try_into().unwrap()) as usize;
        if length < 2 {
            return Err(DecodeError::InvalidData);
        }
        let segment = bytes
            .get(offset + 2..offset + length)
            .ok_or(DecodeError::InvalidData)?;
        offset += length;
        match marker {
            0xc0..=0xc2 => {
                if frame || segment.len() < 6 {
                    return Err(DecodeError::InvalidData);
                }
                if segment[0] != 8 {
                    return Err(DecodeError::UnsupportedColor);
                }
                let height = u16::from_be_bytes([segment[1], segment[2]]) as u32;
                let width = u16::from_be_bytes([segment[3], segment[4]]) as u32;
                if width == 0
                    || height == 0
                    || width > limits.max_dimension
                    || height > limits.max_dimension
                {
                    return Err(DecodeError::LimitExceeded);
                }
                let components = segment[5] as usize;
                if ![1, 3, 4].contains(&components) || segment.len() != 6 + components * 3 {
                    return Err(DecodeError::UnsupportedColor);
                }
                for component in segment[6..].chunks_exact(3) {
                    if !(1..=4).contains(&(component[1] >> 4))
                        || !(1..=4).contains(&(component[1] & 15))
                    {
                        return Err(DecodeError::UnsupportedColor);
                    }
                }
                frame = true;
            }
            0xda => {
                if !frame || scans >= 64 {
                    return Err(DecodeError::InvalidData);
                }
                scans += 1;
                in_scan = true;
                scan_data = false;
            }
            // DHT, DQT, DRI, application metadata and comments.
            0xc4 | 0xdb | 0xdd | 0xe0..=0xef | 0xfe => {}
            _ => return Err(DecodeError::UnsupportedFormat),
        }
    }
    Err(DecodeError::InvalidData)
}
