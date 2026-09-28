use super::{Resource, ResourceStore};
use crate::{
    deformation::Pose,
    resources::{ResourceError, registry::ResourceKey},
    scene::Geometry,
};
use wgpu::util::DeviceExt;
impl ResourceStore {
    pub(crate) fn insert_pose(
        &mut self,
        device: &wgpu::Device,
        pose: &Pose,
        geometry: &Geometry,
    ) -> Result<ResourceKey, ResourceError> {
        let size = pose.byte_length() as u64;
        self.registry.check_capacity(size)?;
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let values = pose.gpu_values(geometry);
        let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("mesh pose"),
            contents: bytemuck::cast_slice(&values),
            usage: wgpu::BufferUsages::STORAGE,
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
}
