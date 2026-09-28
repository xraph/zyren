use super::{BUDGET, DecodeError, DecodeLimits};

#[derive(Debug)]
pub struct DecodedHdrImage {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<f32>,
}

const HEADER_LIMIT: usize = 64 * 1024;
const SRGB_PRIMARIES: [f64; 8] = [0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290];

struct Input<'a> {
    bytes: &'a [u8],
    offset: usize,
}
impl<'a> Input<'a> {
    fn take(&mut self, length: usize) -> Result<&'a [u8], DecodeError> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or(DecodeError::InvalidData)?;
        let result = self
            .bytes
            .get(self.offset..end)
            .ok_or(DecodeError::InvalidData)?;
        self.offset = end;
        Ok(result)
    }
    fn byte(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }
    fn pixel(&mut self) -> Result<[u8; 4], DecodeError> {
        Ok(self.take(4)?.try_into().unwrap())
    }
    fn line(&mut self) -> Result<&'a str, DecodeError> {
        let end = self.bytes.len().min(HEADER_LIMIT);
        if self.offset >= end {
            return Err(if end == HEADER_LIMIT {
                DecodeError::LimitExceeded
            } else {
                DecodeError::InvalidData
            });
        }
        let length = self.bytes[self.offset..end]
            .iter()
            .position(|b| *b == b'\n')
            .ok_or(if end == HEADER_LIMIT {
                DecodeError::LimitExceeded
            } else {
                DecodeError::InvalidData
            })?;
        let bytes = self.take(length + 1)?;
        let text = std::str::from_utf8(&bytes[..length]).map_err(|_| DecodeError::InvalidData)?;
        Ok(text.strip_suffix('\r').unwrap_or(text))
    }
}

fn numbers<const N: usize>(value: &str) -> Result<[f64; N], DecodeError> {
    let mut words = value.split_whitespace();
    let mut result = [0_f64; N];
    for output in &mut result {
        *output = words
            .next()
            .ok_or(DecodeError::InvalidData)?
            .parse()
            .map_err(|_| DecodeError::InvalidData)?;
        if !output.is_finite() || *output <= 0. {
            return Err(DecodeError::InvalidData);
        }
    }
    if words.next().is_some() {
        return Err(DecodeError::InvalidData);
    }
    Ok(result)
}

#[derive(Clone, Copy)]
struct Axis {
    x: bool,
    forward: bool,
    size: u32,
}
impl Axis {
    fn parse(tag: &str, size: &str, limits: DecodeLimits) -> Result<Self, DecodeError> {
        let (x, forward) = match tag {
            "+X" => (true, true),
            "-X" => (true, false),
            "-Y" => (false, true),
            "+Y" => (false, false),
            _ => return Err(DecodeError::InvalidData),
        };
        let size = size.parse::<u64>().map_err(|_| DecodeError::InvalidData)?;
        if size == 0 || size > u64::from(limits.max_dimension) {
            return Err(DecodeError::LimitExceeded);
        }
        Ok(Self {
            x,
            forward,
            size: size as u32,
        })
    }
    fn coordinate(self, index: u32) -> u32 {
        if self.forward {
            index
        } else {
            self.size - 1 - index
        }
    }
}

/// RGBE environment profile: values as stored, linear-sRGB primaries when absent.
/// Explicit other primaries, XYZE and non-square pixels are rejected.
/// Exposure and color correction describe changes already baked into pixels.
pub fn decode_hdr(bytes: &[u8], limits: DecodeLimits) -> Result<DecodedHdrImage, DecodeError> {
    limits.validate()?;
    if bytes.is_empty() {
        return Err(DecodeError::InvalidData);
    }
    if bytes.len() as u64 > limits.max_encoded_bytes {
        return Err(DecodeError::LimitExceeded);
    }
    let _reservation = BUDGET.reserve(limits.max_working_bytes)?;
    let mut input = Input { bytes, offset: 0 };
    if !matches!(input.line()?, "#?RADIANCE" | "#?RGBE") {
        return Err(DecodeError::UnsupportedFormat);
    }
    let mut format = false;
    let mut aspect = 1.;
    let mut exposure = 1.;
    let mut correction = [1.; 3];
    loop {
        let line = input.line()?;
        if line.is_empty() {
            break;
        }
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        match key.trim() {
            "FORMAT" => {
                if format {
                    return Err(DecodeError::InvalidData);
                }
                if value.trim() != "32-bit_rle_rgbe" {
                    return Err(DecodeError::UnsupportedColor);
                }
                format = true;
            }
            "PRIMARIES" => {
                if numbers::<8>(value)?
                    .iter()
                    .zip(SRGB_PRIMARIES)
                    .any(|(a, b)| (a - b).abs() > 0.0001)
                {
                    return Err(DecodeError::UnsupportedColor);
                }
            }
            "EXPOSURE" => exposure *= numbers::<1>(value)?[0],
            "PIXASPECT" => aspect *= numbers::<1>(value)?[0],
            "COLORCORR" => {
                for (a, b) in correction.iter_mut().zip(numbers::<3>(value)?) {
                    *a *= b;
                }
            }
            _ => {}
        }
        if [
            aspect,
            exposure,
            correction[0],
            correction[1],
            correction[2],
        ]
        .iter()
        .any(|v| !v.is_finite() || *v <= 0.)
        {
            return Err(DecodeError::InvalidData);
        }
    }
    if !format {
        return Err(DecodeError::InvalidData);
    }
    if (aspect - 1.).abs() > 0.0001 {
        return Err(DecodeError::UnsupportedColor);
    }
    let mut words = input.line()?.split_whitespace();
    let mut next = || words.next().ok_or(DecodeError::InvalidData);
    let major = Axis::parse(next()?, next()?, limits)?;
    let minor = Axis::parse(next()?, next()?, limits)?;
    if words.next().is_some() || major.x == minor.x {
        return Err(DecodeError::InvalidData);
    }
    let width = if major.x { major.size } else { minor.size };
    let height = if major.x { minor.size } else { major.size };
    let output_bytes = u64::from(width) * u64::from(height) * 16;
    let working_bytes = output_bytes + u64::from(minor.size) * 4 + bytes.len() as u64 * 2 + 4096;
    if output_bytes > limits.max_decoded_bytes || working_bytes > limits.max_working_bytes {
        return Err(DecodeError::LimitExceeded);
    }
    let mut pixels = Vec::new();
    pixels
        .try_reserve_exact(output_bytes as usize / 4)
        .map_err(|_| DecodeError::LimitExceeded)?;
    pixels.resize(output_bytes as usize / 4, 0.);
    let mut scanline = vec![[0; 4]; minor.size as usize];
    for a in 0..major.size {
        read_scanline(&mut input, &mut scanline)?;
        for b in 0..minor.size {
            let (x, y) = if major.x {
                (major.coordinate(a), minor.coordinate(b))
            } else {
                (minor.coordinate(b), major.coordinate(a))
            };
            let offset = ((y * width + x) * 4) as usize;
            let rgbe = scanline[b as usize];
            let scale = if rgbe[3] == 0 {
                0.
            } else {
                f64::from_bits(((i32::from(rgbe[3]) - 136 + 1023) as u64) << 52)
            };
            for channel in 0..3 {
                pixels[offset + channel] = (f64::from(rgbe[channel]) * scale) as f32;
            }
            pixels[offset + 3] = 1.;
        }
    }
    if input.offset != bytes.len() {
        return Err(DecodeError::InvalidData);
    }
    Ok(DecodedHdrImage {
        width,
        height,
        pixels,
    })
}

fn read_scanline(input: &mut Input<'_>, output: &mut [[u8; 4]]) -> Result<(), DecodeError> {
    let first = input.pixel()?;
    if (8..32768).contains(&output.len()) && first[0] == 2 && first[1] == 2 && first[2] < 128 {
        if usize::from(u16::from_be_bytes([first[2], first[3]])) != output.len() {
            return Err(DecodeError::InvalidData);
        }
        for channel in 0..4 {
            let mut offset = 0;
            while offset < output.len() {
                let code = input.byte()?;
                let count = usize::from(if code > 128 { code - 128 } else { code });
                if count == 0 || count > output.len() - offset {
                    return Err(DecodeError::InvalidData);
                }
                if code > 128 {
                    let value = input.byte()?;
                    for pixel in &mut output[offset..offset + count] {
                        pixel[channel] = value;
                    }
                } else {
                    for (pixel, value) in output[offset..offset + count]
                        .iter_mut()
                        .zip(input.take(count)?)
                    {
                        pixel[channel] = *value;
                    }
                }
                offset += count;
            }
        }
    } else {
        let mut offset = 0;
        let mut shift = 0;
        let mut previous = [0; 4];
        let mut pixel = first;
        loop {
            if pixel[..3] == [1, 1, 1] {
                if offset == 0 || shift >= 32 {
                    return Err(DecodeError::InvalidData);
                }
                let count = u64::from(pixel[3]) << shift;
                if count > (output.len() - offset) as u64 {
                    return Err(DecodeError::InvalidData);
                }
                output[offset..offset + count as usize].fill(previous);
                offset += count as usize;
                shift += 8;
            } else {
                output[offset] = pixel;
                previous = pixel;
                offset += 1;
                shift = 0;
            }
            if offset == output.len() {
                break;
            }
            pixel = input.pixel()?;
        }
    }
    Ok(())
}
