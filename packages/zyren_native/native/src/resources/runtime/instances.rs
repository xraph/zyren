use super::{Resource, ResourceStore};
use crate::{
    instances::{INSTANCE_STRIDE, InstancePatch, Instances},
    resources::{ResourceError, registry::ResourceKey},
};
use wgpu::util::DeviceExt;

impl ResourceStore {
    pub(crate) fn insert_instances(
        &mut self,
        device: &wgpu::Device,
        instances: &Instances,
    ) -> Result<ResourceKey, ResourceError> {
        self.insert_instance_values(device, &instances.gpu_values(0..instances.transforms.len()))
    }
    pub(crate) fn insert_instance_values(
        &mut self,
        device: &wgpu::Device,
        values: &[f32],
    ) -> Result<ResourceKey, ResourceError> {
        let size = std::mem::size_of_val(values) as u64;
        self.check_scene_capacity(size, 1)?;
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("mesh instances"),
            contents: bytemuck::cast_slice(values),
            usage: wgpu::BufferUsages::VERTEX
                | wgpu::BufferUsages::COPY_SRC
                | wgpu::BufferUsages::COPY_DST,
        });
        let mut failed = false;
        for scope in [internal, memory, validation] {
            failed |= pollster::block_on(scope.pop()).is_some();
        }
        if failed {
            return Err(ResourceError::DeviceFailed);
        }
        let key = self.registry.insert(
            Resource::Buffer {
                buffer,
                size,
                usage: 0,
            },
            size,
        )?;
        self.uploaded = self.uploaded.saturating_add(size);
        Ok(key)
    }
    pub(crate) fn patch_instances(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        base: ResourceKey,
        instances: &Instances,
        patch: &InstancePatch,
        reuse: bool,
    ) -> Result<ResourceKey, ResourceError> {
        let size = instances.byte_length() as u64;
        if !reuse {
            self.check_scene_capacity(size, 1)?;
        }
        let old = self.graph_buffer(base)?;
        if old.size() != size {
            return Err(ResourceError::InvalidRange);
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let buffer = if reuse {
            old.clone()
        } else {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("instance version"),
                size,
                usage: old.usage(),
                mapped_at_creation: false,
            })
        };
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("instance ranges"),
        });
        if !reuse {
            encoder.copy_buffer_to_buffer(&old, 0, &buffer, 0, size);
        }
        let mut uploaded = 0;
        for range in &patch.ranges {
            let values = instances.gpu_values(range.first..range.first + range.transforms.len());
            let bytes = bytemuck::cast_slice(&values);
            let staging = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("instance dirty range"),
                contents: bytes,
                usage: wgpu::BufferUsages::COPY_SRC,
            });
            encoder.copy_buffer_to_buffer(
                &staging,
                0,
                &buffer,
                (range.first * INSTANCE_STRIDE) as u64,
                bytes.len() as u64,
            );
            uploaded += bytes.len() as u64;
        }
        let command = encoder.finish();
        let mut command = Some(command);
        let mut failed = if self.scene_patches.is_some() {
            false
        } else {
            self.submit(device, queue, [command.take().unwrap()])
                .is_err()
        };
        for scope in [internal, memory, validation] {
            failed |= pollster::block_on(scope.pop()).is_some();
        }
        if failed {
            return Err(ResourceError::DeviceFailed);
        }
        let key = if reuse {
            base
        } else {
            self.registry.insert(
                Resource::Buffer {
                    buffer,
                    size,
                    usage: 0,
                },
                size,
            )?
        };
        if let Some(command) = command {
            self.scene_patches
                .as_mut()
                .unwrap()
                .push((command, vec![base, key]));
        }
        self.registry.mark_used(base, self.serial)?;
        self.registry.mark_used(key, self.serial)?;
        self.uploaded = self.uploaded.saturating_add(uploaded);
        Ok(key)
    }
}
