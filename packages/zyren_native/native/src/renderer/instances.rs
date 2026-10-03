use super::Renderer;
use crate::{
    instances::{Instances, MAX_INSTANCES},
    resources::registry::ResourceKey,
    scene::Frame,
};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

pub(super) struct GpuInstances {
    pub key: ResourceKey,
    pub recipe: Arc<Instances>,
}
impl Renderer {
    pub(super) fn validate_instances(
        &self,
        frame: &Frame,
    ) -> Result<(HashMap<u32, u32>, usize, usize), String> {
        let mut added = HashSet::new();
        for instance in &frame.instances {
            instance.validate()?;
            if !added.insert(instance.id) {
                return Err("duplicate instance upload".into());
            }
            if let Some(old) = self.instances.get(&instance.id)
                && old.recipe.as_ref() != instance
            {
                return Err("instance ID refers to different immutable data".into());
            }
        }
        for patch in &frame.instance_patches {
            if !self.instances.contains_key(&patch.base) || !added.contains(&patch.id) {
                return Err("instance patch base or target is not resident".into());
            }
        }
        let resolve = |id| {
            frame
                .instances
                .iter()
                .find(|i| i.id == id)
                .or_else(|| self.instances.get(&id).map(|i| i.recipe.as_ref()))
                .ok_or("instance resource is not resident")
        };
        let mut slots = 0;
        if let Some(view) = &frame.binary {
            if frame
                .meshes
                .iter()
                .any(|m| m.instances != 0 && !view.retained_instances.contains(&m.instances))
                || frame
                    .instances
                    .iter()
                    .any(|i| !frame.meshes.iter().any(|m| m.instances == i.id))
            {
                return Err("instance resources must be retained and uploads referenced".into());
            }
            for &id in &view.retained_instances {
                slots += resolve(id)?.transforms.len();
            }
        } else if !frame.instances.is_empty() || frame.meshes.iter().any(|m| m.instances != 0) {
            return Err("instances require a binary scene view".into());
        }
        if slots > MAX_INSTANCES {
            return Err("instance view capacity exceeded".into());
        }
        if frame
            .meshes
            .iter()
            .filter(|m| m.instances != 0)
            .map(|m| m.instance_count as usize)
            .sum::<usize>()
            > MAX_INSTANCES
        {
            return Err("instance draw budget exceeded".into());
        }
        for mesh in &frame.meshes {
            if mesh.instances != 0
                && mesh.instance_count as usize > resolve(mesh.instances)?.transforms.len()
            {
                return Err("instance draw count exceeds capacity".into());
            }
        }
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        let reusable: HashMap<_, _> = frame
            .instance_patches
            .iter()
            .filter(|patch| {
                frame.admission.is_none()
                    && !self.instances.contains_key(&patch.id)
                    && frame
                        .instance_patches
                        .iter()
                        .filter(|p| p.base == patch.base)
                        .count()
                        == 1
                    && frame
                        .binary
                        .as_ref()
                        .is_some_and(|v| !v.retained_instances.contains(&patch.base))
                    && !self
                        .views
                        .iter()
                        .any(|(id, v)| *id != view && v.retained_instances.contains(&patch.base))
                    && !self
                        .staging
                        .values()
                        .any(|v| v.retained_instances.contains(&patch.base))
            })
            .map(|p| (p.id, p.base))
            .collect();
        let new: Vec<_> = frame
            .instances
            .iter()
            .filter(|i| !self.instances.contains_key(&i.id) && !reusable.contains_key(&i.id))
            .collect();
        let bytes = new.iter().map(|i| i.byte_length()).sum();
        Ok((reusable, bytes, new.len()))
    }
    pub(super) fn upload_instances(
        &mut self,
        frame: &Frame,
        reusable: &HashMap<u32, u32>,
    ) -> Result<(), String> {
        for instance in &frame.instances {
            if self.instances.contains_key(&instance.id) {
                continue;
            }
            let state = self.state.as_mut().unwrap();
            let result =
                if let Some(patch) = frame.instance_patches.iter().find(|p| p.id == instance.id) {
                    let base = state.instances[&patch.base].key;
                    state.resources.patch_instances(
                        &state.device,
                        &state.queue,
                        base,
                        instance,
                        patch,
                        reusable.contains_key(&instance.id),
                    )
                } else {
                    state.resources.insert_instances(&state.device, instance)
                };
            let key = result.map_err(|e| {
                state.failure = Some(e.to_string());
                e.to_string()
            })?;
            state.instance_uploaded_bytes += frame
                .instance_patches
                .iter()
                .find(|p| p.id == instance.id)
                .map_or(instance.byte_length() as u64, |p| {
                    p.ranges
                        .iter()
                        .map(|r| {
                            r.transforms.len() as u64 * crate::instances::INSTANCE_STRIDE as u64
                        })
                        .sum()
                });
            if let Some(base) = reusable.get(&instance.id) {
                state.instances.remove(base);
            }
            state.instances.insert(
                instance.id,
                GpuInstances {
                    key,
                    recipe: Arc::new(instance.clone()),
                },
            );
        }
        Ok(())
    }
    pub(super) fn evict_instances(&mut self) -> Result<(), String> {
        let retained: HashSet<_> = self
            .views
            .values()
            .chain(self.staging.values())
            .flat_map(|v| v.retained_instances.iter().copied())
            .collect();
        let removed: Vec<_> = self
            .instances
            .keys()
            .filter(|id| !retained.contains(id))
            .copied()
            .collect();
        for id in removed {
            let instance = self.instances.remove(&id).unwrap();
            self.resources
                .release_scene_resource(instance.key)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
