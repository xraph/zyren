use super::{
    ResourceError,
    registry::{ResourceKey, ResourceRegistry, next_registry_id},
    texture_format,
    upload::{Command, MAX_BYTES, Operation, checked_upload_range},
};
use std::{
    collections::VecDeque,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};
const MAX_PENDING_SUBMISSIONS: usize = 32;
const MAX_PENDING_WRITES: usize = 256;
struct PendingSubmission {
    serial: u64,
    graph: bool,
    #[cfg(target_vendor = "apple")]
    metal: crate::interop::metal::MetalCompletion,
}
mod deformation;
mod instances;
mod scene_updates;

enum Resource {
    Geometry {
        vertices: wgpu::Buffer,
        indices: wgpu::Buffer,
        count: u32,
        index_format: wgpu::IndexFormat,
        uv: Option<wgpu::Buffer>,
        tangents: Option<wgpu::Buffer>,
        colors: Option<wgpu::Buffer>,
        deformation: Option<wgpu::Buffer>,
    },
    Buffer {
        buffer: wgpu::Buffer,
        size: u64,
        usage: u32,
    },
    Texture {
        texture: wgpu::Texture,
        usage: u32,
    },
}
/// Aggregate admission includes old and candidate graphs during replacement.
pub const MAX_RESIDENT_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Default)]
struct Telemetry {
    submissions: u64,
    graph_submissions: u64,
    completion_wait_ns: u64,
    gpu_time_ns: Option<u64>,
    graph_gpu_time_ns: Option<u64>,
    gpu_samples: u64,
    graph_gpu_samples: u64,
}

pub struct ResourceStore {
    registry: ResourceRegistry<Resource>,
    optional_batch: Option<ResourceKey>,
    batch_pinned: bool,
    serial: u64,
    uploaded: u64,
    pending: Option<wgpu::SubmissionIndex>,
    completed: Arc<AtomicU64>,
    observations: VecDeque<PendingSubmission>,
    mipmaps: super::mipmap::MipmapGenerator,
    telemetry: Telemetry,
    pending_write_queue: Option<wgpu::Queue>,
    pending_write_bytes: u64,
    pending_write_count: usize,
}
impl Default for ResourceStore {
    fn default() -> Self {
        let renderer = next_registry_id();
        Self {
            registry: ResourceRegistry::new(renderer, 1, MAX_RESIDENT_BYTES),
            optional_batch: None,
            batch_pinned: false,
            serial: 0,
            uploaded: 0,
            pending: None,
            completed: Arc::new(AtomicU64::new(0)),
            observations: VecDeque::new(),
            mipmaps: Default::default(),
            telemetry: Default::default(),
            pending_write_queue: None,
            pending_write_bytes: 0,
            pending_write_count: 0,
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
fn mip_extent(texture: &wgpu::Texture, level: u32) -> Result<wgpu::Extent3d, ResourceError> {
    if level >= texture.mip_level_count() {
        return Err(ResourceError::InvalidRange);
    }
    Ok(wgpu::Extent3d {
        width: (texture.width() >> level).max(1),
        height: (texture.height() >> level).max(1),
        depth_or_array_layers: (texture.depth_or_array_layers() >> level).max(1),
    })
}
impl ResourceStore {
    pub(crate) fn graph_buffer(&self, key: ResourceKey) -> Result<wgpu::Buffer, ResourceError> {
        match self.registry.resolve(key)? {
            Resource::Buffer { buffer, .. } => Ok(buffer.clone()),
            _ => Err(ResourceError::InvalidUsage),
        }
    }
    pub(crate) fn graph_texture(&self, key: ResourceKey) -> Result<wgpu::Texture, ResourceError> {
        match self.registry.resolve(key)? {
            Resource::Texture { texture, .. } => Ok(texture.clone()),
            _ => Err(ResourceError::InvalidUsage),
        }
    }
    pub(crate) fn retain_graph(&mut self, keys: &[ResourceKey]) -> Result<(), ResourceError> {
        for (index, key) in keys.iter().enumerate() {
            if let Err(error) = self.registry.retain(*key) {
                for previous in &keys[..index] {
                    let _ = self.registry.release(*previous);
                }
                return Err(error);
            }
        }
        Ok(())
    }
    pub(crate) fn release_graph(
        &mut self,
        device: &wgpu::Device,
        keys: &[ResourceKey],
    ) -> Result<(), ResourceError> {
        let mut releases = std::collections::HashMap::new();
        for key in keys {
            *releases.entry(*key).or_insert(0_u32) += 1;
        }
        let mut closes_resource = false;
        for (key, count) in releases {
            let references = self.registry.references(key)?;
            if count > references {
                return Err(ResourceError::StaleKey);
            }
            closes_resource |= count == references;
        }
        if closes_resource {
            self.flush_writes(device)?;
        }
        self.poll_completed(device)?;
        for key in keys {
            self.registry.release(*key)?;
        }
        self.registry
            .retire_completed(self.completed.load(Ordering::Acquire));
        Ok(())
    }
    pub(crate) fn execute_graph(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        keys: &[ResourceKey],
        commands: wgpu::CommandBuffer,
    ) -> Result<(), ResourceError> {
        self.submit(device, queue, [commands])?;
        self.telemetry.graph_submissions += 1;
        self.observations.back_mut().unwrap().graph = true;
        for key in keys {
            self.registry.mark_used(*key, self.serial)?;
        }
        Ok(())
    }
    pub(crate) fn register_batch(&mut self, key: Option<ResourceKey>) {
        self.optional_batch = key;
    }
    pub(crate) fn pin_batch(&mut self, pinned: bool) {
        self.batch_pinned = pinned;
    }
    pub(crate) fn batch_is_live(&self, key: ResourceKey) -> bool {
        self.registry.references(key).is_ok_and(|n| n > 0)
    }
    pub(crate) fn release_batch(&mut self, key: ResourceKey) -> Result<(), ResourceError> {
        if self.batch_is_live(key) {
            self.release_scene_resource(key)?;
        }
        self.registry
            .retire_completed(self.completed.load(Ordering::Acquire));
        Ok(())
    }
    pub(crate) fn check_scene_capacity(
        &mut self,
        bytes: u64,
        count: usize,
    ) -> Result<(), ResourceError> {
        self.check_scene_capacity_after_release(bytes, count, &[])
    }
    pub(crate) fn check_scene_capacity_after_release(
        &mut self,
        bytes: u64,
        count: usize,
        keys: &[ResourceKey],
    ) -> Result<(), ResourceError> {
        let completed = self.completed.load(Ordering::Acquire);
        let original = self
            .registry
            .check_batch_after_release(bytes, count, keys, completed);
        if original.is_ok() || self.batch_pinned {
            return original;
        }
        let Some(key) = self
            .optional_batch
            .filter(|key| self.registry.uniquely_completed(*key, completed))
        else {
            return original;
        };
        let mut reclaimed = keys.to_vec();
        reclaimed.push(key);
        self.registry
            .check_batch_after_release(bytes, count, &reclaimed, completed)?;
        // Only the registry owns the optional buffer. Encoding borrows it while pinned.
        self.release_batch(key)?;
        Ok(())
    }
    pub(crate) fn insert_geometry(
        &mut self,
        device: &wgpu::Device,
        geometry: &crate::scene::Geometry,
    ) -> Result<ResourceKey, ResourceError> {
        use wgpu::util::DeviceExt;
        let bytes = geometry.byte_length() as u64;
        self.check_scene_capacity(bytes, 1)?;
        let mut vertices: Vec<[f32; 6]> = geometry
            .positions
            .iter()
            .zip(&geometry.normals)
            .map(|(p, n)| [p[0], p[1], p[2], n[0], n[1], n[2]])
            .collect();
        let mut expanded_indices = Vec::new();
        let mut expanded_colors: Vec<[f32; 8]> = Vec::new();
        if geometry.topology != 0 {
            vertices.clear();
            for primitive in 0..geometry.primitive_count() {
                let (start, end) = match geometry.topology {
                    1 => (primitive * 2, primitive * 2 + 1),
                    2 => (primitive, primitive + 1),
                    _ => (primitive, primitive),
                };
                let a = geometry.positions[geometry.indices[start] as usize];
                let b = geometry.positions[geometry.indices[end] as usize];
                if !geometry.colors.is_empty() {
                    let ca = geometry.colors[geometry.indices[start] as usize];
                    let cb = geometry.colors[geometry.indices[end] as usize];
                    expanded_colors.extend_from_slice(
                        &[[ca[0], ca[1], ca[2], ca[3], cb[0], cb[1], cb[2], cb[3]]; 4],
                    );
                }
                let offset = vertices.len() as u32;
                vertices.extend_from_slice(&[[a[0], a[1], a[2], b[0], b[1], b[2]]; 4]);
                expanded_indices.extend_from_slice(&[
                    offset,
                    offset + 1,
                    offset + 2,
                    offset,
                    offset + 2,
                    offset + 3,
                ]);
            }
        }
        let draw_indices = if geometry.topology == 0 {
            &geometry.indices
        } else {
            &expanded_indices
        };
        let index_format = if geometry.topology == 0 {
            geometry.index_format
        } else {
            crate::scene::IndexFormat::Uint32
        };
        let compact = if index_format == crate::scene::IndexFormat::Uint16 {
            Some(
                geometry
                    .indices
                    .iter()
                    .map(|i| u16::try_from(*i))
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|_| ResourceError::InvalidRange)?,
            )
        } else {
            None
        };
        let index_bytes = match &compact {
            Some(values) => bytemuck::cast_slice(values),
            None => bytemuck::cast_slice(draw_indices),
        };
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let vertices = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("scene vertices"),
            contents: bytemuck::cast_slice(&vertices),
            usage: wgpu::BufferUsages::VERTEX
                | wgpu::BufferUsages::COPY_SRC
                | wgpu::BufferUsages::COPY_DST,
        });
        let indices = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("scene indices"),
            contents: index_bytes,
            usage: wgpu::BufferUsages::INDEX
                | wgpu::BufferUsages::COPY_SRC
                | wgpu::BufferUsages::COPY_DST,
        });
        let uv = if geometry.uv0.is_empty() && geometry.uv1.is_empty() {
            None
        } else {
            let values: Vec<[f32; 4]> = (0..geometry.positions.len())
                .map(|i| {
                    let a = geometry.uv0.get(i).copied().unwrap_or([0.; 2]);
                    let b = geometry.uv1.get(i).copied().unwrap_or([0.; 2]);
                    [a[0], a[1], b[0], b[1]]
                })
                .collect();
            Some(
                device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("scene UVs"),
                    contents: bytemuck::cast_slice(&values),
                    usage: wgpu::BufferUsages::VERTEX
                        | wgpu::BufferUsages::COPY_SRC
                        | wgpu::BufferUsages::COPY_DST,
                }),
            )
        };
        let tangents = (!geometry.tangents.is_empty()).then(|| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("scene tangents"),
                contents: bytemuck::cast_slice(&geometry.tangents),
                usage: wgpu::BufferUsages::VERTEX
                    | wgpu::BufferUsages::COPY_SRC
                    | wgpu::BufferUsages::COPY_DST,
            })
        });
        let colors = (!geometry.colors.is_empty()).then(|| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("scene colors"),
                contents: if geometry.topology == 0 {
                    bytemuck::cast_slice(&geometry.colors)
                } else {
                    bytemuck::cast_slice(&expanded_colors)
                },
                usage: wgpu::BufferUsages::VERTEX
                    | wgpu::BufferUsages::COPY_SRC
                    | wgpu::BufferUsages::COPY_DST,
            })
        });
        let deformation = (geometry.deformation_bytes() > 0).then(|| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("deformation source"),
                contents: bytemuck::cast_slice(&geometry.deformation_values()),
                usage: wgpu::BufferUsages::STORAGE
                    | wgpu::BufferUsages::COPY_SRC
                    | wgpu::BufferUsages::COPY_DST,
            })
        });
        let key = self.registry.insert(
            Resource::Geometry {
                vertices,
                indices,
                count: draw_indices.len() as u32,
                index_format: index_format.native(),
                tangents,
                colors,
                deformation,
                uv,
            },
            bytes,
        )?;
        let mut failed = false;
        for scope in [internal, memory, validation] {
            failed |= pollster::block_on(scope.pop()).is_some();
        }
        if failed {
            return Err(ResourceError::DeviceFailed);
        }
        self.uploaded = self.uploaded.saturating_add(bytes);
        Ok(key)
    }
    pub(crate) fn geometry(
        &self,
        key: ResourceKey,
    ) -> (
        &wgpu::Buffer,
        &wgpu::Buffer,
        u32,
        Option<&wgpu::Buffer>,
        wgpu::IndexFormat,
    ) {
        let Resource::Geometry {
            vertices,
            indices,
            count,
            uv,
            index_format,
            ..
        } = self
            .registry
            .resolve(key)
            .expect("validated scene geometry")
        else {
            unreachable!()
        };
        (vertices, indices, *count, uv.as_ref(), *index_format)
    }
    pub(crate) fn geometry_deformation(&self, key: ResourceKey) -> Option<&wgpu::Buffer> {
        let Resource::Geometry { deformation, .. } =
            self.registry.resolve(key).expect("retained geometry")
        else {
            return None;
        };
        deformation.as_ref()
    }
    pub(crate) fn geometry_colors(&self, key: ResourceKey) -> Option<&wgpu::Buffer> {
        let Resource::Geometry { colors, .. } =
            self.registry.resolve(key).expect("retained geometry")
        else {
            return None;
        };
        colors.as_ref()
    }
    pub(crate) fn geometry_tangents(&self, key: ResourceKey) -> Option<&wgpu::Buffer> {
        let Resource::Geometry { tangents, .. } = self
            .registry
            .resolve(key)
            .expect("validated scene geometry")
        else {
            unreachable!()
        };
        tangents.as_ref()
    }
    pub(crate) fn create_draw_uniform(
        &mut self,
        device: &wgpu::Device,
        size: u64,
    ) -> Result<(ResourceKey, wgpu::Buffer), ResourceError> {
        self.check_scene_capacity(size, 1)?;
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("retained draw uniform"),
            size,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        if pollster::block_on(internal.pop())
            .or(pollster::block_on(memory.pop()))
            .or(pollster::block_on(validation.pop()))
            .is_some()
        {
            return Err(ResourceError::DeviceFailed);
        }
        let key = self.registry.insert(
            Resource::Buffer {
                buffer: buffer.clone(),
                size,
                usage: 4 | 32,
            },
            size,
        )?;
        Ok((key, buffer))
    }
    pub(crate) fn create_frame_target(
        &mut self,
        device: &wgpu::Device,
        size: [u32; 2],
        format: wgpu::TextureFormat,
    ) -> Result<(ResourceKey, wgpu::Texture), ResourceError> {
        let bytes = u64::from(size[0])
            * u64::from(size[1])
            * u64::from(format.block_copy_size(None).unwrap_or(4));
        if bytes > MAX_BYTES {
            return Err(ResourceError::BudgetExceeded);
        }
        self.check_scene_capacity(bytes, 1)?;
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("retained graph resize target"),
            size: wgpu::Extent3d {
                width: size[0],
                height: size[1],
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        if pollster::block_on(internal.pop())
            .or(pollster::block_on(memory.pop()))
            .or(pollster::block_on(validation.pop()))
            .is_some()
        {
            return Err(ResourceError::DeviceFailed);
        }
        let key = self.registry.insert(
            Resource::Texture {
                texture: texture.clone(),
                usage: 3,
            },
            bytes,
        )?;
        Ok((key, texture))
    }
    pub(crate) fn insert_scene_texture(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        image: &crate::scene::SceneTexture,
    ) -> Result<ResourceKey, ResourceError> {
        let format = texture_format::require(device, image.format)?;
        let bytes = image.byte_length() as u64;
        self.check_scene_capacity(bytes, 1)?;
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let texture = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("scene color image"),
            size: wgpu::Extent3d {
                width: image.width,
                height: image.height,
                depth_or_array_layers: 1,
            },
            mip_level_count: image.mip_count(),
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_DST
                | if image.mip_generation != 0 {
                    wgpu::TextureUsages::RENDER_ATTACHMENT
                } else {
                    wgpu::TextureUsages::empty()
                },
            view_formats: &[],
        });
        for (mip, pixels) in image.levels.iter().enumerate() {
            let width = (image.width >> mip).max(1);
            let height = (image.height >> mip).max(1);
            let (extent, row, rows) = texture_format::copy_layout(format, width, height);
            queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: &texture,
                    mip_level: mip as u32,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                pixels,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row),
                    rows_per_image: Some(rows),
                },
                extent,
            );
        }
        let generated = if image.mip_generation != 0 && image.mip_count() > 1 {
            Some(
                self.mipmaps
                    .encode(device, &texture, image.mip_generation == 2),
            )
        } else {
            None
        };
        let mut failed = false;
        for scope in [internal, memory, validation] {
            failed |= pollster::block_on(scope.pop()).is_some();
        }
        if failed {
            return Err(ResourceError::DeviceFailed);
        }
        if let Some(commands) = generated {
            self.submit(device, queue, [commands])?;
        }
        let key = self.registry.insert(
            Resource::Texture {
                texture,
                usage: if image.mip_generation != 0 { 11 } else { 9 },
            },
            bytes,
        )?;
        self.registry.mark_used(key, self.serial)?;
        self.uploaded = self
            .uploaded
            .saturating_add(image.upload_byte_length() as u64);
        Ok(key)
    }
    pub(crate) fn scene_texture(&self, key: ResourceKey) -> &wgpu::Texture {
        let Resource::Texture { texture, .. } =
            self.registry.resolve(key).expect("validated scene texture")
        else {
            unreachable!()
        };
        texture
    }
    pub(crate) fn release_scene_resource(&mut self, key: ResourceKey) -> Result<(), ResourceError> {
        if self.optional_batch == Some(key) {
            self.optional_batch = None;
        }
        self.registry.release(key)
    }
    pub(crate) fn scene_submitted(
        &mut self,
        index: wgpu::SubmissionIndex,
        keys: &[ResourceKey],
    ) -> Result<(), ResourceError> {
        self.serial = self
            .serial
            .checked_add(1)
            .ok_or(ResourceError::DeviceFailed)?;
        self.pending = Some(index);
        self.writes_submitted();
        for key in keys {
            self.registry.mark_used(*key, self.serial)?;
        }
        Ok(())
    }
    pub(crate) fn owned_completed(
        &self,
        key: ResourceKey,
        references: u32,
    ) -> Result<bool, ResourceError> {
        self.registry
            .owned_completed(key, references, self.completed.load(Ordering::Acquire))
    }
    pub(crate) fn prepare_queued_scene(
        &mut self,
        device: &wgpu::Device,
    ) -> Result<(), ResourceError> {
        self.poll_completed(device)?;
        if self
            .serial
            .saturating_sub(self.completed.load(Ordering::Acquire))
            >= MAX_PENDING_SUBMISSIONS as u64
        {
            self.wait(device)?;
        }
        Ok(())
    }
    pub(crate) fn track_queued_scene(&mut self, queue: &wgpu::Queue) {
        let completed = self.completed.clone();
        let serial = self.serial;
        queue.on_submitted_work_done(move || {
            completed.fetch_max(serial, Ordering::Release);
        });
    }
    pub(crate) fn scene_completed(&mut self) -> Result<(), ResourceError> {
        self.batch_pinned = false;
        self.pending = None;
        self.completed.store(self.serial, Ordering::Release);
        self.observe_completed()
    }
    fn observe_completed(&mut self) -> Result<(), ResourceError> {
        let completed = self.completed.load(Ordering::Acquire);
        while self
            .observations
            .front()
            .is_some_and(|p| p.serial <= completed)
        {
            let observation = self.observations.pop_front().unwrap();
            #[cfg(target_vendor = "apple")]
            {
                observation
                    .metal
                    .check()
                    .map_err(|_| ResourceError::DeviceFailed)?;
                if let Some(ns) = observation.metal.gpu_time_ns() {
                    self.telemetry.gpu_samples += 1;
                    self.telemetry.gpu_time_ns =
                        Some(self.telemetry.gpu_time_ns.unwrap_or(0).saturating_add(ns));
                    if observation.graph {
                        self.telemetry.graph_gpu_samples += 1;
                        self.telemetry.graph_gpu_time_ns = Some(
                            self.telemetry
                                .graph_gpu_time_ns
                                .unwrap_or(0)
                                .saturating_add(ns),
                        );
                    }
                }
            }
            let _ = observation;
        }
        self.registry.retire_completed(completed);
        Ok(())
    }
    pub(crate) fn shutdown(&mut self, device: &wgpu::Device) -> Result<(), ResourceError> {
        self.flush_writes(device)?;
        self.wait(device)
    }
    fn flush_writes(&mut self, device: &wgpu::Device) -> Result<(), ResourceError> {
        if let Some(queue) = self.pending_write_queue.clone() {
            self.submit(device, &queue, [])?;
        }
        Ok(())
    }
    fn prepare_write(&mut self, device: &wgpu::Device, bytes: u64) -> Result<(), ResourceError> {
        if self.pending_write_bytes.saturating_add(bytes) > MAX_BYTES
            || self.pending_write_count >= MAX_PENDING_WRITES
        {
            self.flush_writes(device)?;
        }
        Ok(())
    }
    fn record_write(
        &mut self,
        queue: &wgpu::Queue,
        key: ResourceKey,
        bytes: u64,
    ) -> Result<(), ResourceError> {
        // The next queue submission consumes these writes. Retain resources
        // against that future serial even when their owner closes first.
        let serial = self
            .serial
            .checked_add(1)
            .ok_or(ResourceError::DeviceFailed)?;
        self.registry.mark_used(key, serial)?;
        self.pending_write_queue
            .get_or_insert_with(|| queue.clone());
        self.pending_write_bytes += bytes;
        self.pending_write_count += 1;
        Ok(())
    }
    fn writes_submitted(&mut self) {
        self.pending_write_queue = None;
        self.pending_write_bytes = 0;
        self.pending_write_count = 0;
    }
    pub(crate) fn poll_completed(&mut self, device: &wgpu::Device) -> Result<(), ResourceError> {
        device
            .poll(wgpu::PollType::Poll)
            .map_err(|_| ResourceError::DeviceFailed)?;
        self.observe_completed()
    }
    pub(crate) fn inspection(&self, limit: usize) -> serde_json::Value {
        let allocations: Vec<_> = self.registry.inspect(limit).into_iter().map(
            |(key, resource, bytes, references, submission)| serde_json::json!({
                "id": format!("{}:{}:{}:{}", key.renderer, key.device_generation, key.slot, key.slot_generation),
                "kind": match resource {Resource::Geometry {..} => "geometry", Resource::Buffer {..} => "buffer", Resource::Texture {..} => "texture"},
                "payloadBytes": bytes, "references": references, "lastSubmission": submission
            })).collect();
        serde_json::json!({"registryPayloadBytes": self.registry.resident_bytes(),
            "totalAllocations": self.registry.live_allocations(), "allocations": allocations,
            "residentBytes": null})
    }
    // Device-lifetime resource queue observations. Scene submissions are
    // excluded; uploads, mip generation, readbacks and standalone graphs overlap.
    pub(crate) fn telemetry(&self) -> serde_json::Value {
        serde_json::json!({
            "submissionCount": self.telemetry.submissions,
            "graphSubmissionCount": self.telemetry.graph_submissions,
            "cpuCompletionWaitNs": self.telemetry.completion_wait_ns,
            "gpuTimeNs": self.telemetry.gpu_time_ns.filter(|_| self.telemetry.gpu_samples == self.telemetry.submissions),
            "gpuMeasuredSubmissionCount": self.telemetry.gpu_samples,
            "graphGpuTimeNs": self.telemetry.graph_gpu_time_ns.filter(|_| self.telemetry.graph_gpu_samples == self.telemetry.graph_submissions),
            "graphGpuMeasuredSubmissionCount": self.telemetry.graph_gpu_samples,
            "gpuTimeSource": if self.telemetry.gpu_time_ns.is_some() { "metal.commandBuffer.startEndTime" } else { "unavailable" },
            "uploadedBytes": self.uploaded,
            "pendingWriteBytes": self.pending_write_bytes,
            "pendingWriteCount": self.pending_write_count,
        })
    }
    pub(crate) fn stats(&self) -> (u64, u64) {
        (self.registry.resident_bytes(), self.uploaded)
    }
    fn submit(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        commands: impl IntoIterator<Item = wgpu::CommandBuffer>,
    ) -> Result<(), ResourceError> {
        self.poll_completed(device)?;
        if self.observations.len() >= MAX_PENDING_SUBMISSIONS {
            self.wait(device)?;
        }
        self.serial = self
            .serial
            .checked_add(1)
            .ok_or(ResourceError::DeviceFailed)?;
        let index = queue.submit(commands);
        self.writes_submitted();
        self.telemetry.submissions += 1;
        #[cfg(target_vendor = "apple")]
        let metal = crate::interop::metal::MetalCompletion::capture(queue)
            .map_err(|_| ResourceError::DeviceFailed)?;
        self.observations.push_back(PendingSubmission {
            serial: self.serial,
            graph: false,
            #[cfg(target_vendor = "apple")]
            metal,
        });
        let completed = self.completed.clone();
        let serial = self.serial;
        queue.on_submitted_work_done(move || {
            completed.fetch_max(serial, Ordering::Release);
        });
        self.pending = Some(index);
        Ok(())
    }
    fn wait(&mut self, device: &wgpu::Device) -> Result<(), ResourceError> {
        if let Some(pending) = &self.pending {
            let wait_started = std::time::Instant::now();
            let completion = device
                .poll(wgpu::PollType::Wait {
                    submission_index: Some(pending.clone()),
                    timeout: Some(Duration::from_secs(2)),
                })
                .map_err(|_| ResourceError::DeviceFailed);
            self.telemetry.completion_wait_ns = self
                .telemetry
                .completion_wait_ns
                .saturating_add(wait_started.elapsed().as_nanos() as u64);
            completion?;
        }
        self.pending = None;
        self.completed.store(self.serial, Ordering::Release);
        self.observe_completed()
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
            Operation::TextureFormats => 4,
            Operation::ReadBuffer(_, _, length) => *length,
            Operation::ReadTexture(key, mip) => {
                let Resource::Texture { texture, .. } = self.registry.resolve(*key)? else {
                    return Err(ResourceError::InvalidUsage);
                };
                let extent = mip_extent(texture, *mip)?;
                let (_, row, rows) =
                    texture_format::copy_layout(texture.format(), extent.width, extent.height);
                u64::from(row) * u64::from(rows)
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
                if d.size > device.limits().max_buffer_size {
                    return Err(ResourceError::InvalidRange);
                }
                self.check_scene_capacity(d.size, 1)?;
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
                let format = texture_format::require(device, d.format)?;
                let maximum = if d.dimension == 1 {
                    device.limits().max_texture_dimension_3d
                } else {
                    device.limits().max_texture_dimension_2d
                };
                if d.width > maximum || d.height > maximum || d.depth > maximum {
                    return Err(ResourceError::InvalidRange);
                }
                self.check_scene_capacity(d.byte_length(), 1)?;
                let flags = [
                    wgpu::TextureUsages::TEXTURE_BINDING,
                    wgpu::TextureUsages::RENDER_ATTACHMENT,
                    wgpu::TextureUsages::COPY_SRC,
                    wgpu::TextureUsages::COPY_DST,
                    wgpu::TextureUsages::STORAGE_BINDING,
                ];
                let usage = flags
                    .into_iter()
                    .enumerate()
                    .filter(|(i, _)| d.usage & (1 << i) != 0)
                    .fold(wgpu::TextureUsages::empty(), |a, (_, b)| a | b);

                if !format
                    .guaranteed_format_features(device.features())
                    .allowed_usages
                    .contains(usage)
                {
                    return Err(ResourceError::InvalidUsage);
                }
                let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
                let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
                let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
                let texture = device.create_texture(&wgpu::TextureDescriptor {
                    label: Some(d.label),
                    size: wgpu::Extent3d {
                        width: d.width,
                        height: d.height,
                        depth_or_array_layers: d.depth,
                    },
                    mip_level_count: d.mip_levels,
                    sample_count: 1,
                    dimension: if d.dimension == 1 {
                        wgpu::TextureDimension::D3
                    } else {
                        wgpu::TextureDimension::D2
                    },
                    format,
                    usage,
                    view_formats: &[],
                });
                let mut failed = false;
                for scope in [internal, memory, validation] {
                    failed |= pollster::block_on(scope.pop()).is_some();
                }
                if failed {
                    return Err(ResourceError::DeviceFailed);
                }
                key_bytes(self.registry.insert(
                    Resource::Texture {
                        texture,
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
                let buffer = buffer.clone();
                self.prepare_write(device, data.len() as u64)?;
                queue.write_buffer(&buffer, offset, data);
                self.record_write(queue, key, data.len() as u64)?;
                self.uploaded = self.uploaded.saturating_add(data.len() as u64);
                Vec::new()
            }
            Operation::WriteTexture(key, level, data) => {
                let Resource::Texture { texture, usage } = self.registry.resolve(key)? else {
                    return Err(ResourceError::InvalidUsage);
                };
                if usage & 8 == 0 {
                    return Err(ResourceError::InvalidUsage);
                }
                let extent = mip_extent(texture, level)?;
                let depth = extent.depth_or_array_layers;
                let (mut extent, row, rows) =
                    texture_format::copy_layout(texture.format(), extent.width, extent.height);
                extent.depth_or_array_layers = depth;
                if data.len() as u64 != u64::from(row) * u64::from(rows) * u64::from(depth) {
                    return Err(ResourceError::InvalidRange);
                }
                let texture = texture.clone();
                self.prepare_write(device, data.len() as u64)?;
                queue.write_texture(
                    wgpu::TexelCopyTextureInfo {
                        texture: &texture,
                        mip_level: level,
                        origin: wgpu::Origin3d::ZERO,
                        aspect: wgpu::TextureAspect::All,
                    },
                    data,
                    wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(row),
                        rows_per_image: Some(rows),
                    },
                    extent,
                );
                self.record_write(queue, key, data.len() as u64)?;
                self.uploaded = self.uploaded.saturating_add(data.len() as u64);
                Vec::new()
            }
            Operation::GenerateMipmaps(key, alpha_filter) => {
                let Resource::Texture { texture, usage, .. } = self.registry.resolve(key)? else {
                    return Err(ResourceError::InvalidUsage);
                };
                if usage & 3 != 3 {
                    return Err(ResourceError::InvalidUsage);
                }
                if texture.mip_level_count() > 1 {
                    let texture = texture.clone();
                    let commands = self.mipmaps.encode(device, &texture, alpha_filter == 1);
                    self.submit(device, queue, [commands])?;
                    self.registry.mark_used(key, self.serial)?;
                }
                Vec::new()
            }
            Operation::Retain(key) => {
                self.registry.retain(key)?;
                Vec::new()
            }
            Operation::Release(key) => {
                self.registry.resolve(key)?;
                self.flush_writes(device)?;
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
                let Resource::Texture { texture, usage } = self.registry.resolve(key)? else {
                    return Err(ResourceError::InvalidUsage);
                };
                if usage & 4 == 0 {
                    return Err(ResourceError::InvalidUsage);
                }
                let extent = mip_extent(texture, level)?;
                let depth = extent.depth_or_array_layers;
                let (mut extent, row, rows) =
                    texture_format::copy_layout(texture.format(), extent.width, extent.height);
                extent.depth_or_array_layers = depth;
                let stride = row.div_ceil(256) * 256;
                let staging = device.create_buffer(&wgpu::BufferDescriptor {
                    label: Some("texture readback"),
                    size: stride as u64 * rows as u64 * depth as u64,
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
                            rows_per_image: Some(rows),
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
            Operation::TextureFormats => texture_format::supported_mask(device)
                .to_le_bytes()
                .to_vec(),
            Operation::ConfigureBudget(bytes) => {
                self.registry.configure_limit(bytes)?;
                Vec::new()
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

#[cfg(test)]
mod telemetry_tests {
    use super::*;
    #[test]
    fn incomplete_resource_gpu_coverage_stays_null() {
        let mut store = ResourceStore::default();
        store.telemetry.submissions = 2;
        store.telemetry.gpu_samples = 1;
        store.telemetry.gpu_time_ns = Some(100);
        store.telemetry.graph_submissions = 1;
        store.telemetry.graph_gpu_time_ns = Some(100);
        assert!(store.telemetry()["gpuTimeNs"].is_null());
        assert!(store.telemetry()["graphGpuTimeNs"].is_null());
        store.telemetry.gpu_samples = 2;
        store.telemetry.graph_gpu_samples = 1;
        assert_eq!(store.telemetry()["gpuTimeNs"], 100);
        assert_eq!(store.telemetry()["graphGpuTimeNs"], 100);
    }
}

#[cfg(test)]
mod batch_capacity_tests {
    use super::*;
    fn create(size: u64) -> Vec<u8> {
        let body = [
            size.to_le_bytes().as_slice(),
            48_u32.to_le_bytes().as_slice(),
            0_u32.to_le_bytes().as_slice(),
        ]
        .concat();
        [
            2_u32.to_le_bytes().as_slice(),
            1_u32.to_le_bytes().as_slice(),
            1_u64.to_le_bytes().as_slice(),
            (body.len() as u64).to_le_bytes().as_slice(),
            &body,
        ]
        .concat()
    }
    #[test]
    #[ignore = "requires a native GPU"]
    fn optional_batch_reclaim_obeys_complete_request_pin_and_submission_ownership() {
        let renderer = pollster::block_on(crate::renderer::Renderer::new()).unwrap();
        let mut store = ResourceStore::default();
        store.registry.configure_limit(1024).unwrap();
        let key = store
            .insert_instance_values(&renderer.device, &[0.; 128])
            .unwrap();
        store.register_batch(Some(key));
        store.pin_batch(true);
        assert_eq!(
            store.execute(&renderer.device, &renderer.queue, &create(768), 56),
            Err(ResourceError::BudgetExceeded)
        );
        assert!(store.batch_is_live(key));
        store.pin_batch(false);
        assert_eq!(
            store.execute(&renderer.device, &renderer.queue, &create(2048), 56),
            Err(ResourceError::BudgetExceeded)
        );
        assert!(store.batch_is_live(key));
        store.registry.retain(key).unwrap();
        assert_eq!(
            store.execute(&renderer.device, &renderer.queue, &create(768), 56),
            Err(ResourceError::BudgetExceeded)
        );
        store.registry.release(key).unwrap();
        store.registry.mark_used(key, 1).unwrap();
        assert_eq!(
            store.execute(&renderer.device, &renderer.queue, &create(768), 56),
            Err(ResourceError::BudgetExceeded)
        );
        store.completed.store(1, Ordering::Release);
        let reply = store
            .execute(&renderer.device, &renderer.queue, &create(768), 56)
            .unwrap();
        assert_eq!(reply.len(), 56);
        assert!(!store.batch_is_live(key));
        assert_eq!(store.registry.resident_bytes(), 768);
        assert!(store.optional_batch.is_none());
    }
}
