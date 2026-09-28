use super::{ResourceError, registry::ResourceKey};
use std::ops::Range;

pub const MAX_BYTES: u64 = 64 * 1024 * 1024;
pub const MAX_COMMAND_BYTES: usize = MAX_BYTES as usize + 2048;

pub fn checked_upload_range(
    offset: u64,
    length: u64,
    capacity: u64,
) -> Result<Range<u64>, ResourceError> {
    let end = offset
        .checked_add(length)
        .ok_or(ResourceError::InvalidRange)?;
    if end > capacity {
        return Err(ResourceError::InvalidRange);
    }
    Ok(offset..end)
}
#[derive(Debug)]
pub struct BufferDescriptor<'a> {
    pub size: u64,
    pub usage: u32,
    pub label: &'a str,
}
#[derive(Debug)]
pub struct TextureDescriptor<'a> {
    pub width: u32,
    pub height: u32,
    pub mip_levels: u32,
    pub format: u32,
    pub usage: u32,
    pub label: &'a str,
}
impl TextureDescriptor<'_> {
    pub fn byte_length(&self) -> u64 {
        (0..self.mip_levels)
            .map(|m| (self.width >> m).max(1) as u64 * (self.height >> m).max(1) as u64 * 4)
            .sum()
    }
}
#[derive(Debug)]
pub enum Operation<'a> {
    CreateBuffer(BufferDescriptor<'a>),
    WriteBuffer(ResourceKey, u64, &'a [u8]),
    CreateTexture(TextureDescriptor<'a>),
    WriteTexture(ResourceKey, u32, &'a [u8]),
    Retain(ResourceKey),
    Release(ResourceKey),
    ReadBuffer(ResourceKey, u64, u64),
    Stats,
    ReadTexture(ResourceKey, u32),
    GenerateMipmaps(ResourceKey, u32),
}
#[derive(Debug)]
pub struct Command<'a> {
    pub request_id: u64,
    pub operation: Operation<'a>,
}
struct Reader<'a> {
    bytes: &'a [u8],
    cursor: usize,
}
impl<'a> Reader<'a> {
    fn bytes(&mut self, length: u64) -> Result<&'a [u8], ResourceError> {
        let range = checked_upload_range(self.cursor as u64, length, self.bytes.len() as u64)?;
        self.cursor = range.end as usize;
        Ok(&self.bytes[range.start as usize..range.end as usize])
    }
    fn u32(&mut self) -> Result<u32, ResourceError> {
        Ok(u32::from_le_bytes(self.bytes(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, ResourceError> {
        Ok(u64::from_le_bytes(self.bytes(8)?.try_into().unwrap()))
    }
    fn key(&mut self) -> Result<ResourceKey, ResourceError> {
        Ok(ResourceKey {
            renderer: self.u64()?,
            device_generation: self.u64()?,
            slot: self.u64()?,
            slot_generation: self.u64()?,
        })
    }
    fn label(&mut self) -> Result<&'a str, ResourceError> {
        let length = self.u32()?;
        if length > 1024 {
            return Err(ResourceError::InvalidCommand);
        }
        std::str::from_utf8(self.bytes(length as u64)?).map_err(|_| ResourceError::InvalidCommand)
    }
    fn payload(&mut self) -> Result<&'a [u8], ResourceError> {
        let length = self.u64()?;
        self.bytes(length)
    }
}
impl<'a> Command<'a> {
    pub fn decode(bytes: &'a [u8]) -> Result<Self, ResourceError> {
        if bytes.len() > MAX_COMMAND_BYTES {
            return Err(ResourceError::BudgetExceeded);
        }
        let mut r = Reader { bytes, cursor: 0 };
        if r.u32()? != 2 {
            return Err(ResourceError::InvalidCommand);
        }
        let opcode = r.u32()?;
        let request_id = r.u64()?;
        let length = r.u64()?;
        if length != (bytes.len() - r.cursor) as u64 {
            return Err(ResourceError::InvalidCommand);
        }
        let operation = match opcode {
            1 => {
                let size = r.u64()?;
                let usage = r.u32()?;
                let label = r.label()?;
                if size == 0 || size > MAX_BYTES || size % 4 != 0 {
                    return Err(ResourceError::InvalidRange);
                }
                if usage == 0 || usage & !63 != 0 {
                    return Err(ResourceError::InvalidUsage);
                }
                Operation::CreateBuffer(BufferDescriptor { size, usage, label })
            }
            2 => Operation::WriteBuffer(r.key()?, r.u64()?, r.payload()?),
            3 => {
                let width = r.u32()?;
                let height = r.u32()?;
                let mip_levels = r.u32()?;
                let format = r.u32()?;
                let usage = r.u32()?;
                let label = r.label()?;
                if width == 0
                    || height == 0
                    || width > 4096
                    || height > 4096
                    || mip_levels == 0
                    || mip_levels > 32 - width.max(height).leading_zeros()
                    || format > 1
                {
                    return Err(ResourceError::InvalidCommand);
                }
                if usage == 0 || usage & !31 != 0 || (usage & 16 != 0 && format != 0) {
                    return Err(ResourceError::InvalidUsage);
                }
                let descriptor = TextureDescriptor {
                    width,
                    height,
                    mip_levels,
                    format,
                    usage,
                    label,
                };
                if descriptor.byte_length() > MAX_BYTES {
                    return Err(ResourceError::BudgetExceeded);
                }
                Operation::CreateTexture(descriptor)
            }
            4 => Operation::WriteTexture(r.key()?, r.u32()?, r.payload()?),
            5 => Operation::Retain(r.key()?),
            6 => Operation::Release(r.key()?),
            7 => Operation::ReadBuffer(r.key()?, r.u64()?, r.u64()?),
            8 => Operation::Stats,
            9 => Operation::ReadTexture(r.key()?, r.u32()?),
            10 => {
                let key = r.key()?;
                let alpha_filter = r.u32()?;
                if alpha_filter > 1 {
                    return Err(ResourceError::InvalidCommand);
                }
                Operation::GenerateMipmaps(key, alpha_filter)
            }
            _ => return Err(ResourceError::InvalidCommand),
        };
        if r.cursor != bytes.len() {
            return Err(ResourceError::InvalidCommand);
        }
        Ok(Self {
            request_id,
            operation,
        })
    }
}
