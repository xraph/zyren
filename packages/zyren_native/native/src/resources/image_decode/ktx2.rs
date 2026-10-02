use super::{BUDGET, DecodeError, DecodeLimits, MIB};
use basisu_c_sys::{
    common::{TF_ASTC_LDR_4X4_RGBA, TF_BC7_RGBA, TF_ETC2_RGBA, TF_RGBA32},
    transcoder as basis,
};
use std::sync::Once;

pub mod ffi;
const MAGIC: &[u8] = b"\xabKTX 20\xbb\r\n\x1a\n";
static INIT: Once = Once::new();

fn word(bytes: &[u8], offset: usize) -> Result<u32, DecodeError> {
    Ok(u32::from_le_bytes(
        bytes
            .get(offset..offset + 4)
            .ok_or(DecodeError::InvalidData)?
            .try_into()
            .unwrap(),
    ))
}
fn wide(bytes: &[u8], offset: usize) -> Result<u64, DecodeError> {
    Ok(u64::from_le_bytes(
        bytes
            .get(offset..offset + 8)
            .ok_or(DecodeError::InvalidData)?
            .try_into()
            .unwrap(),
    ))
}
fn range(
    bytes: &[u8],
    offset: u64,
    length: u64,
    floor: usize,
) -> Result<std::ops::Range<usize>, DecodeError> {
    if offset < floor as u64
        || length == 0
        || offset > bytes.len() as u64
        || length > bytes.len() as u64 - offset
    {
        return Err(DecodeError::InvalidData);
    }
    Ok(offset as usize..(offset + length) as usize)
}

struct Header {
    width: u32,
    height: u32,
    levels: u32,
    srgb: bool,
    payload: usize,
}
fn inspect(bytes: &[u8], limits: DecodeLimits, target: u32) -> Result<Header, DecodeError> {
    if !bytes.starts_with(MAGIC) {
        return Err(DecodeError::UnsupportedFormat);
    }
    if bytes.len() < 104 {
        return Err(DecodeError::InvalidData);
    }
    let width = word(bytes, 20)?;
    let height = word(bytes, 24)?;
    if width == 0 || height == 0 {
        return Err(DecodeError::InvalidData);
    }
    if width > limits.max_dimension || height > limits.max_dimension {
        return Err(DecodeError::LimitExceeded);
    }
    let levels = word(bytes, 40)?;
    if levels == 0 || levels > width.max(height).ilog2() + 1 {
        return Err(DecodeError::InvalidData);
    }
    // This profile is the two-dimensional LDR subset used by KHR_texture_basisu.
    if word(bytes, 12)? != 0
        || word(bytes, 16)? != 1
        || word(bytes, 28)? != 0
        || word(bytes, 32)? != 0
        || word(bytes, 36)? != 1
        || width % 4 != 0
        || height % 4 != 0
    {
        return Err(DecodeError::UnsupportedFormat);
    }
    let floor = 80 + levels as usize * 24;
    let dfd = range(
        bytes,
        word(bytes, 48)? as u64,
        word(bytes, 52)? as u64,
        floor,
    )?;
    if dfd.len() < 44 || dfd.len() > 60 || dfd.start % 4 != 0 {
        return Err(DecodeError::InvalidData);
    }
    let d = &bytes[dfd.clone()];
    if word(d, 0)? as usize != d.len()
        || word(d, 4)? != 0
        || u16::from_le_bytes(d[8..10].try_into().unwrap()) != 2
        || u16::from_le_bytes(d[10..12].try_into().unwrap()) as usize != d.len() - 4
        || d[16..20] != [3, 3, 0, 0]
    {
        return Err(DecodeError::UnsupportedFormat);
    }
    let compression = word(bytes, 44)?;
    let etc = d[12] == 163 && compression == 1;
    let uastc = d[12] == 166 && (compression == 0 || compression == 2);
    if !etc && !uastc {
        return Err(DecodeError::UnsupportedFormat);
    }
    if d[15] != 0 || !matches!(d[14], 1 | 2) || d[13] > 1 || (d[14] == 2 && d[13] != 1) {
        return Err(DecodeError::UnsupportedColor);
    }
    let mut ranges = vec![dfd];
    let kv_length = word(bytes, 60)? as u64;
    if kv_length > 64 * 1024 {
        return Err(DecodeError::LimitExceeded);
    }
    if kv_length > 0 {
        let kv = range(bytes, word(bytes, 56)? as u64, kv_length, floor)?;
        if kv.start % 4 != 0 || kv.len() % 4 != 0 {
            return Err(DecodeError::InvalidData);
        }
        let mut p = kv.start;
        let mut count = 0;
        let mut keys = std::collections::HashSet::new();
        while p < kv.end {
            count += 1;
            if count > 256 {
                return Err(DecodeError::LimitExceeded);
            }
            let len = word(bytes, p)? as usize;
            p += 4;
            let end = p
                .checked_add(len)
                .filter(|end| *end <= kv.end)
                .ok_or(DecodeError::InvalidData)?;
            let entry = &bytes[p..end];
            let split = entry
                .iter()
                .position(|x| *x == 0)
                .ok_or(DecodeError::InvalidData)?;
            let key = &entry[..split];
            if key.is_empty() || !keys.insert(key) {
                return Err(DecodeError::InvalidData);
            }
            let value = &entry[split + 1..];
            let value = value.strip_suffix(&[0]).unwrap_or(value);
            if (key == b"KTXorientation" && value != b"rd")
                || (key == b"KTXswizzle" && value != b"rgba")
                || key == b"KTXanimData"
            {
                return Err(DecodeError::UnsupportedFormat);
            }
            p = end.checked_add(3).ok_or(DecodeError::InvalidData)? & !3;
            if p > kv.end || bytes[end..p].iter().any(|x| *x != 0) {
                return Err(DecodeError::InvalidData);
            }
        }
        ranges.push(kv);
    } else if word(bytes, 56)? != 0 {
        return Err(DecodeError::InvalidData);
    }
    let sgd_length = wide(bytes, 72)?;
    if etc {
        let sgd = range(bytes, wide(bytes, 64)?, sgd_length, floor)?;
        if sgd.start % 8 != 0 || sgd.len() < 20 + levels as usize * 20 {
            return Err(DecodeError::InvalidData);
        }
        let data = &bytes[sgd.clone()];
        let mut expected = 20 + levels as usize * 20;
        for p in [4, 8, 12, 16] {
            expected = expected
                .checked_add(word(data, p)? as usize)
                .ok_or(DecodeError::InvalidData)?;
        }
        if expected != sgd.len() {
            return Err(DecodeError::InvalidData);
        }
        for i in 0..levels as usize {
            // Video prediction is outside the still-texture profile.
            if word(data, 20 + i * 20)? != 0 {
                return Err(DecodeError::UnsupportedFormat);
            }
        }
        ranges.push(sgd);
    } else if sgd_length != 0 || wide(bytes, 64)? != 0 {
        return Err(DecodeError::InvalidData);
    }
    let mut payload = 0u64;
    for i in 0..levels {
        let p = 80 + i as usize * 24;
        let length = wide(bytes, p + 8)?;
        let level = range(bytes, wide(bytes, p)?, length, floor)?;
        let uncompressed = wide(bytes, p + 16)?;
        let w = (width >> i).max(1) as u64;
        let h = (height >> i).max(1) as u64;
        if etc {
            if uncompressed != 0 {
                return Err(DecodeError::InvalidData);
            }
        } else {
            let blocks = w.div_ceil(4) * h.div_ceil(4) * 16;
            if uncompressed != blocks
                || (compression == 0 && (length != blocks || level.start % 16 != 0))
            {
                return Err(DecodeError::InvalidData);
            }
        }
        payload += if target == 0 {
            w * h * 4
        } else {
            w.div_ceil(4) * h.div_ceil(4) * 16
        };
        ranges.push(level);
    }
    ranges.sort_by_key(|r| r.start);
    if ranges.windows(2).any(|r| r[0].end > r[1].start) {
        return Err(DecodeError::InvalidData);
    }
    if payload > limits.max_decoded_bytes {
        return Err(DecodeError::LimitExceeded);
    }
    // Admission estimate: borrowed bytes and metadata, RGBA result, one inflated
    // UASTC level, ETC1S block history and bounded palette/Huffman workspace.
    // The upstream allocator has no hard budget; this is not an RSS ceiling.
    let blocks = u64::from(width).div_ceil(4) * u64::from(height).div_ceil(4);
    let working = bytes.len() as u64 * 2 + payload + blocks * 48 + 16 * MIB;
    if working > limits.max_working_bytes {
        return Err(DecodeError::LimitExceeded);
    }
    Ok(Header {
        width,
        height,
        levels,
        srgb: d[14] == 2,
        payload: payload as usize,
    })
}

struct Handle(u64);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { basis::bt_ktx2_close(self.0) };
    }
}

/// Returns width, height, sRGB flag, level count, then length/pixels per level.
pub fn decode(bytes: &[u8], limits: DecodeLimits) -> Result<Vec<u8>, DecodeError> {
    transcode(bytes, limits, 0)
}

/// Target 0: RGBA8, 1: BC7, 2: ETC2 RGBA8, 3: ASTC 4x4. Transfer is retained.
pub fn transcode(bytes: &[u8], limits: DecodeLimits, target: u32) -> Result<Vec<u8>, DecodeError> {
    let basis_format = match target {
        0 => TF_RGBA32,
        1 => TF_BC7_RGBA,
        2 => TF_ETC2_RGBA,
        3 => TF_ASTC_LDR_4X4_RGBA,
        _ => return Err(DecodeError::UnsupportedFormat),
    };
    limits.validate()?;
    if bytes.len() as u64 > limits.max_encoded_bytes {
        return Err(DecodeError::LimitExceeded);
    }
    let _reservation = BUDGET.reserve(limits.max_working_bytes)?;
    let header = inspect(bytes, limits, target)?;
    INIT.call_once(|| unsafe {
        basis::bt_init();
        basis::bt_enable_debug_printf(0);
    });
    let handle = Handle(unsafe { basis::bt_ktx2_open(bytes.as_ptr() as u64, bytes.len() as u32) });
    if handle.0 == 0 {
        return Err(DecodeError::InvalidData);
    }
    if unsafe {
        basis::bt_ktx2_is_video(handle.0).is_ok()
            || basis::bt_ktx2_start_transcoding(handle.0).is_err()
    } {
        return Err(DecodeError::InvalidData);
    }
    let total = 16 + header.levels as usize * 4 + header.payload;
    let mut packet = Vec::new();
    packet
        .try_reserve_exact(total)
        .map_err(|_| DecodeError::LimitExceeded)?;
    for value in [
        header.width,
        header.height,
        (if target == 0 { 0 } else { target * 2 + 1 }) + header.srgb as u32,
        header.levels,
    ] {
        packet.extend(value.to_le_bytes());
    }
    for i in 0..header.levels {
        let w = (header.width >> i).max(1);
        let h = (header.height >> i).max(1);
        if unsafe { basis::bt_ktx2_get_level_orig_width(handle.0, i, 0, 0) } != w
            || unsafe { basis::bt_ktx2_get_level_orig_height(handle.0, i, 0, 0) } != h
        {
            return Err(DecodeError::InvalidData);
        }
        let units = if target == 0 {
            w * h
        } else {
            w.div_ceil(4) * h.div_ceil(4)
        };
        let len = units * if target == 0 { 4 } else { 16 };
        packet.extend(len.to_le_bytes());
        let offset = packet.len();
        packet.resize(offset + len as usize, 0);
        if unsafe {
            basis::bt_ktx2_transcode_image_level(
                handle.0,
                i,
                0,
                0,
                packet.as_mut_ptr().add(offset) as u64,
                units,
                basis_format,
                0,
                0,
                0,
                -1,
                -1,
                0,
            )
            .is_err()
        } {
            return Err(DecodeError::InvalidData);
        }
    }
    Ok(packet)
}

#[cfg(test)]
mod tests {
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    use super::*;
    const ETC: &[u8] =
        include_bytes!("../../../../../../test_assets/compression/colors-etc1s.ktx2");
    const UASTC: &[u8] =
        include_bytes!("../../../../../../test_assets/compression/colors-uastc.ktx2");
    const ZSTD: &[u8] =
        include_bytes!("../../../../../../test_assets/compression/colors-zstd.ktx2");
    fn u32_at(bytes: &[u8], offset: usize) -> u32 {
        u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
    }
    #[test]
    fn compressed_targets_keep_all_mip_blocks_with_bounded_output() {
        let _guard = TEST_LOCK.lock().unwrap();
        for source in [ETC, UASTC, ZSTD] {
            for (target, format) in [(1, 4), (2, 6), (3, 8)] {
                let limits = DecodeLimits {
                    max_decoded_bytes: 112,
                    ..DecodeLimits::default()
                };
                let packet = transcode(source, limits, target).unwrap();
                assert_eq!(u32_at(&packet, 8), format);
                assert_eq!(packet.len(), 144);
                let mut p = 16;
                for length in [64, 16, 16, 16] {
                    assert_eq!(u32_at(&packet, p), length);
                    p += 4 + length as usize;
                }
                assert_eq!(
                    transcode(
                        source,
                        DecodeLimits {
                            max_decoded_bytes: 111,
                            ..limits
                        },
                        target
                    )
                    .unwrap_err(),
                    DecodeError::LimitExceeded
                );
            }
        }
        assert_eq!(
            transcode(UASTC, DecodeLimits::default(), 4).unwrap_err(),
            DecodeError::UnsupportedFormat
        );
    }
    #[test]
    fn preserves_linear_transfer_and_checks_orientation() {
        let _guard = TEST_LOCK.lock().unwrap();
        let mut linear = UASTC.to_vec();
        let d = u32_at(&linear, 48) as usize;
        linear[d + 13] = 0;
        linear[d + 14] = 1;
        assert_eq!(
            u32_at(&decode(&linear, DecodeLimits::default()).unwrap(), 8),
            0
        );
        for (entry, accepted) in [
            (&b"KTXorientation\0rd\0"[..], true),
            (&b"KTXorientation\0ru\0"[..], false),
            (&b"KTXswizzle\0bgra\0"[..], false),
            (&b"KTXanimData\0x\0"[..], false),
        ] {
            let mut bytes = UASTC.to_vec();
            let start = u32_at(&bytes, 56) as usize;
            let old_length = u32_at(&bytes, 60) as usize;
            bytes[start..start + old_length].fill(0);
            bytes[start..start + 4].copy_from_slice(&(entry.len() as u32).to_le_bytes());
            bytes[start + 4..start + 4 + entry.len()].copy_from_slice(entry);
            let length = (entry.len() + 4).next_multiple_of(4);
            bytes[60..64].copy_from_slice(&(length as u32).to_le_bytes());
            assert_eq!(decode(&bytes, DecodeLimits::default()).is_ok(), accepted);
        }
    }
    #[test]
    fn ffi_owns_clears_and_recovers_packet_storage() {
        let _guard = TEST_LOCK.lock().unwrap();
        use super::ffi::*;
        use crate::resources::image_decode::ffi::ImageLimits;
        let mut output = TextureBytes::default();
        let limits = ImageLimits::default();
        unsafe {
            assert_eq!(
                fg2_ktx2_decode(UASTC.as_ptr(), UASTC.len(), &limits, &mut output),
                0
            );
            assert!(!output.data.is_null());
            assert_eq!(output.length, 372);
            fg2_ktx2_free(&mut output);
            fg2_ktx2_free(&mut output);
            assert!(output.data.is_null());
            assert_eq!(output.length, 0);
            assert_eq!(
                fg2_ktx2_decode(std::ptr::null(), 0, &limits, &mut output),
                1
            );
            assert!(output.data.is_null());
        }
    }
    #[test]
    fn transcodes_three_codecs_with_alpha_and_authored_mips() {
        let _guard = TEST_LOCK.lock().unwrap();
        for source in [ETC, UASTC, ZSTD] {
            let packet = decode(source, DecodeLimits::default()).unwrap();
            assert_eq!((u32_at(&packet, 0), u32_at(&packet, 4)), (8, 8));
            assert_eq!(u32_at(&packet, 8), 1); // sRGB
            assert_eq!(u32_at(&packet, 12), 4);
            assert_eq!(u32_at(&packet, 16), 256);
            assert!(packet[20] > 200 && packet[22] < 40 && packet[23] == 255);
            assert!(packet[20 + 4 * 6 + 2] > 200 && packet[20 + 4 * 6 + 3] < 110);
            assert_eq!(packet.len(), 16 + 16 + 256 + 64 + 16 + 4);
        }
    }
    #[test]
    fn rejects_truncation_and_limits_before_allocation() {
        let _guard = TEST_LOCK.lock().unwrap();
        for source in [ETC, UASTC, ZSTD] {
            for length in 0..source.len() {
                assert!(decode(&source[..length], DecodeLimits::default()).is_err());
            }
            for limits in [
                DecodeLimits {
                    max_decoded_bytes: 339,
                    ..DecodeLimits::default()
                },
                DecodeLimits {
                    max_dimension: 4,
                    ..DecodeLimits::default()
                },
                DecodeLimits {
                    max_working_bytes: 1024,
                    ..DecodeLimits::default()
                },
            ] {
                assert_eq!(
                    decode(source, limits).unwrap_err(),
                    DecodeError::LimitExceeded
                );
            }
        }
    }
    #[test]
    fn rejects_hostile_ranges_layouts_and_metadata() {
        let _guard = TEST_LOCK.lock().unwrap();
        for (offset, value) in [(20, u32::MAX), (32, 1), (36, 6), (40, 999), (80, u32::MAX)] {
            let mut bytes = UASTC.to_vec();
            bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
            assert!(decode(&bytes, DecodeLimits::default()).is_err());
        }
        let dfd = u32_at(UASTC, 48) as usize;
        for (offset, value) in [(dfd + 12, 167), (dfd + 14, 10), (dfd + 15, 1)] {
            let mut bytes = UASTC.to_vec();
            bytes[offset] = value;
            assert!(decode(&bytes, DecodeLimits::default()).is_err());
        }
        let mut bytes = ZSTD.to_vec();
        bytes[96..104].copy_from_slice(&u64::MAX.to_le_bytes());
        assert!(decode(&bytes, DecodeLimits::default()).is_err());
    }
}
