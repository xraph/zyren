use super::Renderer;
use crate::{deformation::Pose, resources::registry::ResourceKey, scene::Frame};
use std::{collections::HashSet, sync::Arc};
#[derive(Clone)]
pub(super) struct GpuPose {
    pub key: ResourceKey,
    pub recipe: Arc<Pose>,
    pub binding: wgpu::BindGroup,
    pub center: glam::Vec3,
}
pub(super) fn layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("mesh deformation"),
        entries: &[0, 1].map(|binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::VERTEX,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Storage { read_only: true },
                has_dynamic_offset: false,
                min_binding_size: None,
            },
            count: None,
        }),
    })
}
impl Renderer {
    pub(super) fn validate_poses(&self, frame: &Frame) -> Result<(usize, usize), String> {
        let geometry = |id| {
            frame
                .geometries
                .iter()
                .find(|g| g.id == id)
                .or_else(|| self.geometries.get(&id).map(|g| g.recipe.as_ref()))
                .ok_or("pose geometry not resident")
        };
        let maxima: std::collections::HashMap<_, _> = frame
            .geometries
            .iter()
            .map(|g| (g.id, g.joints.iter().flatten().copied().max()))
            .collect();
        let resolve = |id| {
            frame
                .poses
                .iter()
                .find(|p| p.id == id)
                .or_else(|| self.poses.get(&id).map(|p| p.recipe.as_ref()))
                .ok_or("pose not resident")
        };
        let mut added = HashSet::new();
        let mut bytes = 0;
        let mut count = 0;
        for pose in &frame.poses {
            let source = geometry(pose.geometry)?;
            let max_joint = maxima
                .get(&pose.geometry)
                .copied()
                .unwrap_or_else(|| self.geometries[&pose.geometry].deformation_bounds.max_joint);
            pose.validate_with_max_joint(source, max_joint)?;
            if !added.insert(pose.id) {
                return Err("duplicate pose upload".into());
            }
            if let Some(old) = self.poses.get(&pose.id) {
                if old.recipe.as_ref() != pose {
                    return Err("pose ID refers to different immutable data".into());
                }
            } else {
                bytes += pose.byte_length();
                count += 1;
            }
        }
        if let Some(view) = &frame.binary {
            for id in &view.retained_poses {
                if !view.retained.contains(&resolve(*id)?.geometry) {
                    return Err("retained poses require retained source geometry".into());
                }
            }
            if frame
                .poses
                .iter()
                .any(|p| !frame.meshes.iter().any(|m| m.pose == p.id))
            {
                return Err("pose uploads must be referenced".into());
            }
            for mesh in &frame.meshes {
                if mesh.pose != 0 {
                    if !view.retained_poses.contains(&mesh.pose) {
                        return Err("visible pose must be retained".into());
                    }
                    let pose = resolve(mesh.pose)?;
                    if pose.geometry != mesh.geometry {
                        return Err("pose geometry mismatch".into());
                    }
                } else if !geometry(mesh.geometry)?.morphs.is_empty() {
                    return Err("morph geometry requires a pose".into());
                }
            }
        } else if !frame.poses.is_empty()
            || frame.meshes.iter().any(|m| {
                m.pose != 0 || geometry(m.geometry).is_ok_and(|g| g.deformation_bytes() > 0)
            })
        {
            return Err("deformation requires a binary scene view".into());
        }
        Ok((bytes, count))
    }
    pub(super) fn upload_poses(&mut self, frame: &Frame) -> Result<(), String> {
        for pose in &frame.poses {
            if self.poses.contains_key(&pose.id) {
                continue;
            }
            let state = self.state.as_mut().unwrap();
            let geometry = &state.geometries[&pose.geometry];
            let key = state
                .resources
                .insert_pose(&state.device, pose, &geometry.recipe)
                .map_err(|e| {
                    state.failure = Some(e.to_string());
                    e.to_string()
                })?;
            let buffer = state
                .resources
                .graph_buffer(key)
                .map_err(|e| e.to_string())?;
            let source = state
                .resources
                .geometry_deformation(geometry.key)
                .ok_or("missing deformation source")?;
            let binding = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("mesh pose"),
                layout: &state.deformation_layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: source.as_entire_binding(),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: buffer.as_entire_binding(),
                    },
                ],
            });
            state.poses.insert(
                pose.id,
                GpuPose {
                    key,
                    binding,
                    center: pose.center(&geometry.deformation_bounds),
                    recipe: Arc::new(pose.clone()),
                },
            );
        }
        Ok(())
    }
    pub(super) fn evict_poses(&mut self) -> Result<(), String> {
        let retained: HashSet<_> = self
            .views
            .values()
            .chain(self.staging.values())
            .flat_map(|v| v.retained_poses.iter().copied())
            .collect();
        let removed: Vec<_> = self
            .poses
            .keys()
            .filter(|id| !retained.contains(id))
            .copied()
            .collect();
        for id in removed {
            let pose = self.poses.remove(&id).unwrap();
            self.resources
                .release_scene_resource(pose.key)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
