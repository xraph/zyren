use super::{Resource, ResourceStore};
use crate::resources::{ResourceError, registry::ResourceKey};
use crate::scene::{Geometry, GeometryPatch};
use wgpu::util::DeviceExt;

impl ResourceStore {
    pub(crate) fn patch_geometry(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        base: ResourceKey,
        geometry: &Geometry,
        patch: &GeometryPatch,
        reuse: bool,
    ) -> Result<ResourceKey, ResourceError> {
        if !reuse {
            self.registry
                .check_capacity(geometry.byte_length() as u64)?;
        }
        let Resource::Geometry {
            vertices,
            indices,
            count,
            uv,
            tangents,
            index_format,
        } = self.registry.resolve(base)?
        else {
            return Err(ResourceError::InvalidRange);
        };
        if uv.is_none() && patch.gpu_ranges().iter().any(|range| range.0 == 1) {
            return Err(ResourceError::InvalidRange);
        }
        if tangents.is_none() && patch.gpu_ranges().iter().any(|range| range.0 == 2) {
            return Err(ResourceError::InvalidRange);
        }
        let old_tangents = tangents.clone();
        let index_format = *index_format;
        let (old_vertices, old_indices, old_count, old_uv) =
            (vertices.clone(), indices.clone(), *count, uv.clone());
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let clone_buffer = |source: &wgpu::Buffer| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("geometry version"),
                size: source.size(),
                usage: source.usage(),
                mapped_at_creation: false,
            })
        };
        let vertices = if reuse {
            old_vertices.clone()
        } else {
            clone_buffer(&old_vertices)
        };
        let indices = if reuse {
            old_indices.clone()
        } else {
            clone_buffer(&old_indices)
        };
        let uv = old_uv
            .as_ref()
            .map(|b| if reuse { b.clone() } else { clone_buffer(b) });
        let tangents = old_tangents
            .as_ref()
            .map(|b| if reuse { b.clone() } else { clone_buffer(b) });
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("geometry ranges"),
        });
        if !reuse {
            encoder.copy_buffer_to_buffer(&old_vertices, 0, &vertices, 0, old_vertices.size());
            encoder.copy_buffer_to_buffer(&old_indices, 0, &indices, 0, old_indices.size());
            if let (Some(old), Some(new)) = (&old_tangents, &tangents) {
                encoder.copy_buffer_to_buffer(old, 0, new, 0, old.size());
            }
            if let (Some(old), Some(new)) = (&old_uv, &uv) {
                encoder.copy_buffer_to_buffer(old, 0, new, 0, old.size());
            }
        }
        let mut uploaded = 0;
        for (buffer, first, end) in patch.gpu_ranges() {
            let (values, target, stride): (Vec<f32>, &wgpu::Buffer, u64) = if buffer == 0 {
                (
                    (first..end)
                        .flat_map(|i| geometry.positions[i].into_iter().chain(geometry.normals[i]))
                        .collect(),
                    &vertices,
                    24,
                )
            } else if buffer == 1 {
                (
                    (first..end)
                        .flat_map(|i| {
                            geometry
                                .uv0
                                .get(i)
                                .copied()
                                .unwrap_or([0.; 2])
                                .into_iter()
                                .chain(geometry.uv1.get(i).copied().unwrap_or([0.; 2]))
                        })
                        .collect(),
                    uv.as_ref().expect("UV ranges were preflighted"),
                    16,
                )
            } else {
                (
                    (first..end).flat_map(|i| geometry.tangents[i]).collect(),
                    tangents.as_ref().expect("tangent ranges were preflighted"),
                    16,
                )
            };
            let bytes = bytemuck::cast_slice(&values);
            let staging = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("geometry dirty range"),
                contents: bytes,
                usage: wgpu::BufferUsages::COPY_SRC,
            });
            encoder.copy_buffer_to_buffer(
                &staging,
                0,
                target,
                first as u64 * stride,
                bytes.len() as u64,
            );
            uploaded += bytes.len() as u64;
        }
        let result = self.submit(device, queue, [encoder.finish()]);
        let mut failed = result.is_err();
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
                Resource::Geometry {
                    vertices,
                    indices,
                    count: old_count,
                    uv,
                    tangents,
                    index_format,
                },
                geometry.byte_length() as u64,
            )?
        };
        self.registry.mark_used(base, self.serial)?;
        self.registry.mark_used(key, self.serial)?;
        self.uploaded = self.uploaded.saturating_add(uploaded);
        Ok(key)
    }
}
