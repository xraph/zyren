use super::{
    ResourceError,
    registry::{ResourceKey, ResourceRegistry},
    upload::{Command, MAX_BYTES, Operation, checked_upload_range},
};
use std::{
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
static NEXT_DEVICE: AtomicU64 = AtomicU64::new(1);

enum Resource {
    Buffer {
        buffer: wgpu::Buffer,
        size: u64,
        usage: u32,
    },
    Texture {
        texture: wgpu::Texture,
        width: u32,
        height: u32,
        mips: u32,
        usage: u32,
    },
}
pub struct ResourceStore {
    registry: ResourceRegistry<Resource>,
    serial: u64,
    uploaded: u64,
    pending: Option<wgpu::SubmissionIndex>,
}
impl Default for ResourceStore {
    fn default() -> Self {
        let renderer = NEXT_DEVICE
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |id| id.checked_add(1))
            .expect("resource device IDs exhausted");
        Self {
            registry: ResourceRegistry::new(renderer, 1, MAX_BYTES),
            serial: 0,
            uploaded: 0,
            pending: None,
        }
    }
}
fn key_bytes(key: ResourceKey) -> Vec<u8> {
    [
        key.renderer,
        key.device_generation,
        key.slot,
        key.slot_generation,
    ]
    .into_iter()
    .flat_map(u64::to_le_bytes)
    .collect()
}
fn aligned_range(offset: u64, length: u64, size: u64) -> Result<(), ResourceError> {
    checked_upload_range(offset, length, size)?;
    if !offset.is_multiple_of(4) || length == 0 || !length.is_multiple_of(4) {
        return Err(ResourceError::InvalidRange);
    }
    Ok(())
}
fn mip_extent(
    width: u32,
    height: u32,
    mips: u32,
    level: u32,
) -> Result<wgpu::Extent3d, ResourceError> {
    if level >= mips {
        return Err(ResourceError::InvalidRange);
    }
    Ok(wgpu::Extent3d {
        width: (width >> level).max(1),
        height: (height >> level).max(1),
        depth_or_array_layers: 1,
    })
}
impl ResourceStore {
    fn submit(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        commands: impl IntoIterator<Item = wgpu::CommandBuffer>,
    ) -> Result<(), ResourceError> {
        self.serial = self
            .serial
            .checked_add(1)
            .ok_or(ResourceError::DeviceFailed)?;
        let index = queue.submit(commands);
        #[cfg(target_vendor = "apple")]
        {
            let metal = crate::interop::metal::MetalCompletion::capture(queue)
                .map_err(|_| ResourceError::DeviceFailed)?;
            device
                .poll(wgpu::PollType::Wait {
                    submission_index: Some(index.clone()),
                    timeout: Some(Duration::from_secs(2)),
                })
                .map_err(|_| ResourceError::DeviceFailed)?;
            metal.check().map_err(|_| ResourceError::DeviceFailed)?;
        }
        let _ = device;
        self.pending = Some(index);
        Ok(())
    }
    fn wait(&mut self, device: &wgpu::Device) -> Result<(), ResourceError> {
        if let Some(pending) = &self.pending {
            device
                .poll(wgpu::PollType::Wait {
                    submission_index: Some(pending.clone()),
                    timeout: Some(Duration::from_secs(2)),
                })
                .map_err(|_| ResourceError::DeviceFailed)?;
        }
        self.pending = None;
        self.registry.retire_completed(self.serial);
        Ok(())
    }
    fn readback(
        &mut self,
        device: &wgpu::Device,
        buffer: &wgpu::Buffer,
    ) -> Result<Vec<u8>, ResourceError> {
        let (tx, rx) = std::sync::mpsc::channel();
        buffer
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = tx.send(result);
            });
        self.wait(device)?;
        rx.recv_timeout(Duration::from_secs(2))
            .map_err(|_| ResourceError::DeviceFailed)?
            .map_err(|_| ResourceError::DeviceFailed)?;
        let result = buffer
            .slice(..)
            .get_mapped_range()
            .map_err(|_| ResourceError::DeviceFailed)?
            .to_vec();
        buffer.unmap();
        Ok(result)
    }
    pub fn execute(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        bytes: &[u8],
        capacity: usize,
    ) -> Result<Vec<u8>, ResourceError> {
        let command = Command::decode(bytes)?;
        // Reserve the complete response before any mutation, including creates.
        let response_length = match &command.operation {
            Operation::CreateBuffer(_) | Operation::CreateTexture(_) => 32,
            Operation::Stats => 24,
            Operation::ReadBuffer(_, _, length) => *length,
            Operation::ReadTexture(key, mip) => {
                let Resource::Texture {
                    width,
                    height,
                    mips,
                    ..
                } = self.registry.resolve(*key)?
                else {
                    return Err(ResourceError::InvalidUsage);
                };
                let extent = mip_extent(*width, *height, *mips, *mip)?;
                extent.width as u64 * extent.height as u64 * 4
            }
            _ => 0,
        };
        if response_length > MAX_BYTES
            || response_length
                .checked_add(24)
                .is_none_or(|len| len > capacity as u64)
        {
            return Err(ResourceError::InvalidRange);
        }
        let body = match command.operation {
            Operation::CreateBuffer(d) => {
                self.registry.check_capacity(d.size)?;
                if d.size > device.limits().max_buffer_size {
                    return Err(ResourceError::InvalidRange);
                }
                let flags = [
                    wgpu::BufferUsages::VERTEX,
                    wgpu::BufferUsages::INDEX,
                    wgpu::BufferUsages::UNIFORM,
                    wgpu::BufferUsages::STORAGE,
                    wgpu::BufferUsages::COPY_SRC,
                    wgpu::BufferUsages::COPY_DST,
                ];
                let usage = flags
                    .into_iter()
                    .enumerate()
                    .filter(|(i, _)| d.usage & (1 << i) != 0)
                    .fold(wgpu::BufferUsages::empty(), |a, (_, b)| a | b);
                let buffer = device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some(d.label),
                    size: d.size,
                    usage,
                    mapped_at_creation: false,
                });
                key_bytes(self.registry.insert(
                    Resource::Buffer {
                        buffer,
                        size: d.size,
                        usage: d.usage,
                    },
                    d.size,
                )?)
            }
            Operation::CreateTexture(d) => {
                self.registry.check_capacity(d.byte_length())?;
                if d.width > device.limits().max_texture_dimension_2d
                    || d.height > device.limits().max_texture_dimension_2d
                {
                    return Err(ResourceError::InvalidRange);
                }
                let flags = [
                    wgpu::TextureUsages::TEXTURE_BINDING,
                    wgpu::TextureUsages::RENDER_ATTACHMENT,
                    wgpu::TextureUsages::COPY_SRC,
                    wgpu::TextureUsages::COPY_DST,
                ];
                let usage = flags
                    .into_iter()
                    .enumerate()
                    .filter(|(i, _)| d.usage & (1 << i) != 0)
                    .fold(wgpu::TextureUsages::empty(), |a, (_, b)| a | b);
                let texture = device.create_texture(&wgpu::TextureDescriptor {
                    label: Some(d.label),
                    size: wgpu::Extent3d {
                        width: d.width,
                        height: d.height,
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: d.mip_levels,
                    sample_count: 1,
                    dimension: wgpu::TextureDimension::D2,
                    format: if d.format == 0 {
                        wgpu::TextureFormat::Rgba8Unorm
                    } else {
                        wgpu::TextureFormat::Rgba8UnormSrgb
                    },
                    usage,
                    view_formats: &[],
                });
                key_bytes(self.registry.insert(
                    Resource::Texture {
                        texture,
                        width: d.width,
                        height: d.height,
                        mips: d.mip_levels,
                        usage: d.usage,
                    },
                    d.byte_length(),
                )?)
            }
            Operation::WriteBuffer(key, offset, data) => {
                let Resource::Buffer {
                    buffer,
                    size,
                    usage,
                } = self.registry.resolve(key)?
                else {
                    return Err(ResourceError::InvalidUsage);
                };
                if usage & 32 == 0 {
                    return Err(ResourceError::InvalidUsage);
                }
                aligned_range(offset, data.len() as u64, *size)?;
                queue.write_buffer(buffer, offset, data);
                self.submit(device, queue, [])?;
                self.registry.mark_used(key, self.serial)?;
                self.uploaded = self.uploaded.saturating_add(data.len() as u64);
                Vec::new()
            }
            Operation::WriteTexture(key, level, data) => {
                let Resource::Texture {
                    texture,
                    width,
                    height,
                    mips,
                    usage,
                } = self.registry.resolve(key)?
                else {
                    return Err(ResourceError::InvalidUsage);
                };
                if usage & 8 == 0 {
                    return Err(ResourceError::InvalidUsage);
                }
                let extent = mip_extent(*width, *height, *mips, level)?;
                if data.len() as u64 != extent.width as u64 * extent.height as u64 * 4 {
                    return Err(ResourceError::InvalidRange);
                }
                queue.write_texture(
                    wgpu::TexelCopyTextureInfo {
                        texture,
                        mip_level: level,
                        origin: wgpu::Origin3d::ZERO,
                        aspect: wgpu::TextureAspect::All,
                    },
                    data,
                    wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(extent.width * 4),
                        rows_per_image: Some(extent.height),
                    },
                    extent,
                );
                self.submit(device, queue, [])?;
                self.registry.mark_used(key, self.serial)?;
                self.uploaded = self.uploaded.saturating_add(data.len() as u64);
                Vec::new()
            }
            Operation::Retain(key) => {
                self.registry.retain(key)?;
                Vec::new()
            }
            Operation::Release(key) => {
                self.registry.release(key)?;
                self.wait(device)?;
                Vec::new()
            }
            Operation::ReadBuffer(key, offset, length) => {
                let Resource::Buffer {
                    buffer,
                    size,
                    usage,
                } = self.registry.resolve(key)?
                else {
                    return Err(ResourceError::InvalidUsage);
                };
                if usage & 16 == 0 {
                    return Err(ResourceError::InvalidUsage);
                }
                aligned_range(offset, length, *size)?;
                let staging = device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("resource readback"),
                    size: length,
                    usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                    mapped_at_creation: false,
                });
                let mut encoder = device.create_command_encoder(&Default::default());
                encoder.copy_buffer_to_buffer(buffer, offset, &staging, 0, length);
                self.submit(device, queue, [encoder.finish()])?;
                self.registry.mark_used(key, self.serial)?;
                self.readback(device, &staging)?
            }
            Operation::ReadTexture(key, level) => {
                let Resource::Texture {
                    texture,
                    width,
                    height,
                    mips,
                    usage,
                } = self.registry.resolve(key)?
                else {
                    return Err(ResourceError::InvalidUsage);
                };
                if usage & 4 == 0 {
                    return Err(ResourceError::InvalidUsage);
                }
                let extent = mip_extent(*width, *height, *mips, level)?;
                let row = extent.width * 4;
                let stride = row.div_ceil(256) * 256;
                let staging = device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("texture readback"),
                    size: stride as u64 * extent.height as u64,
                    usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                    mapped_at_creation: false,
                });
                let mut encoder = device.create_command_encoder(&Default::default());
                encoder.copy_texture_to_buffer(
                    wgpu::TexelCopyTextureInfo {
                        texture,
                        mip_level: level,
                        origin: wgpu::Origin3d::ZERO,
                        aspect: wgpu::TextureAspect::All,
                    },
                    wgpu::TexelCopyBufferInfo {
                        buffer: &staging,
                        layout: wgpu::TexelCopyBufferLayout {
                            offset: 0,
                            bytes_per_row: Some(stride),
                            rows_per_image: Some(extent.height),
                        },
                    },
                    extent,
                );
                self.submit(device, queue, [encoder.finish()])?;
                self.registry.mark_used(key, self.serial)?;
                self.readback(device, &staging)?
                    .chunks_exact(stride as usize)
                    .flat_map(|r| r[..row as usize].iter().copied())
                    .collect()
            }
            Operation::Stats => [
                self.registry.resident_bytes(),
                self.uploaded,
                self.registry.live_allocations(),
            ]
            .into_iter()
            .flat_map(u64::to_le_bytes)
            .collect(),
        };
        let mut response = Vec::with_capacity(24 + body.len());
        response.extend(2_u32.to_le_bytes());
        response.extend(0_u32.to_le_bytes());
        response.extend(command.request_id.to_le_bytes());
        response.extend((body.len() as u64).to_le_bytes());
        response.extend(body);
        Ok(response)
    }
}
