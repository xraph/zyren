use super::*;
use crate::scene_packet::{Admission, ViewState};

impl Renderer {
    pub(super) fn prepare_admission(&mut self, admission: &Admission) -> Result<(), String> {
        if admission.publish {
            return Ok(());
        }
        if !self.staging.contains_key(&admission.view) && self.staging.len() >= 64 {
            return Err("staging view limit exceeded".into());
        }
        let frame = admission
            .upload
            .as_ref()
            .ok_or("missing staged resources")?;
        let wanted: HashSet<_> = admission
            .resources
            .iter()
            .map(|r| (r[0], r[1] as u32))
            .collect();
        // Abandon only resources absent from the new candidate. Camera changes
        // and reordered candidates keep matching immutable uploads.
        if let Some(staged) = self.staging.get_mut(&admission.view) {
            staged.retained.retain(|id| wanted.contains(&(0, *id)));
            staged
                .retained_textures
                .retain(|id| wanted.contains(&(1, *id)));
            staged
                .retained_instances
                .retain(|id| wanted.contains(&(2, *id)));
            staged
                .retained_poses
                .retain(|id| wanted.contains(&(3, *id)));
        }
        self.evict_geometry()?;
        let mut reserved = 0_u64;
        let mut count = 0;
        for [kind, id, bytes] in &admission.resources {
            let id = *id as u32;
            let present = match kind {
                0 => self.geometries.contains_key(&id),
                1 => self.textures.contains_key(&id),
                2 => self.instances.contains_key(&id),
                _ => self.poses.contains_key(&id),
            };
            if !present {
                reserved = reserved
                    .checked_add(*bytes)
                    .ok_or("scene reservation overflow")?;
                count += 1;
            }
        }
        let mut actual = Vec::new();
        for geometry in &frame.geometries {
            geometry.validate()?;
            if self
                .geometries
                .get(&geometry.id)
                .is_some_and(|g| g.recipe.as_ref() != geometry)
            {
                return Err("staged geometry is immutable".into());
            }
            actual.push([0, geometry.id as u64, geometry.byte_length() as u64]);
        }
        for texture in &frame.textures {
            texture.validate()?;
            crate::resources::texture_format::require(&self.device, texture.format)
                .map_err(|e| e.to_string())?;
            if self
                .textures
                .get(&texture.id)
                .is_some_and(|t| t.recipe.as_ref() != texture)
            {
                return Err("staged texture is immutable".into());
            }
            actual.push([1, texture.id as u64, texture.byte_length() as u64]);
        }
        for instance in &frame.instances {
            instance.validate()?;
            if self
                .instances
                .get(&instance.id)
                .is_some_and(|i| i.recipe.as_ref() != instance)
            {
                return Err("staged instance is immutable".into());
            }
            actual.push([2, instance.id as u64, instance.byte_length() as u64]);
        }
        // Pose validation includes source geometry, and its uploaded set does
        // not claim visible mesh ownership.
        let mut validation = frame.as_ref().clone();
        validation.binary = None;
        if !frame.poses.is_empty() {
            // validate_poses checks the source and immutable identity before
            // checking draw ownership. Supply references only for validation.
            let mut view = frame.binary.as_ref().unwrap().clone();
            for pose in &frame.poses {
                view.retained.insert(pose.geometry);
                let mesh = crate::scene::Mesh {
                    geometry: pose.geometry,
                    pose: pose.id,
                    ..Default::default()
                };
                validation.meshes.push(mesh);
                actual.push([3, pose.id as u64, pose.byte_length() as u64]);
            }
            validation.binary = Some(view);
            self.validate_poses(&validation)?;
        }
        if actual
            .iter()
            .any(|entry| !admission.resources.contains(entry))
        {
            return Err("staging allocation differs from reservation".into());
        }
        let bytes: u64 = actual
            .iter()
            .filter(|r| r[0] != 1)
            .map(|r| r[2])
            .sum::<u64>()
            + frame
                .textures
                .iter()
                .map(|t| t.upload_byte_length() as u64)
                .sum::<u64>();
        if bytes > 64 * 1024 * 1024 {
            return Err("staging upload exceeds frame budget".into());
        }
        self.resources
            .check_scene_capacity(reserved, count)
            .map_err(|e| format!("candidate and published cover exceed resident capacity: {e}"))?;
        let mut owned = self
            .staging
            .get(&admission.view)
            .cloned()
            .unwrap_or(ViewState {
                view: admission.view,
                revision: 0,
                retained: HashSet::new(),
                meshes: vec![],
                retained_textures: HashSet::new(),
                retained_instances: HashSet::new(),
                retained_poses: HashSet::new(),
            });
        for geometry in &frame.geometries {
            if !self.geometries.contains_key(&geometry.id) {
                let state = self.state.as_mut().unwrap();
                let key = state
                    .resources
                    .insert_geometry(&state.device, geometry)
                    .map_err(|e| {
                        state.failure = Some(e.to_string());
                        e.to_string()
                    })?;
                state.geometries.insert(
                    geometry.id,
                    GpuGeometry {
                        key,
                        recipe: std::sync::Arc::new(geometry.clone()),
                        center: draw_order::geometry_center(geometry),
                        bounds: batching::Bounds::geometry(geometry),
                        deformation_bounds: crate::deformation::SourceBounds::new(geometry),
                    },
                );
            }
            owned.retained.insert(geometry.id);
        }
        self.upload_textures(frame)?;
        self.upload_instances(frame, &HashMap::new())?;
        self.upload_poses(frame)?;
        owned
            .retained_textures
            .extend(frame.textures.iter().map(|t| t.id));
        owned
            .retained_instances
            .extend(frame.instances.iter().map(|i| i.id));
        owned
            .retained_poses
            .extend(frame.poses.iter().map(|p| p.id));
        self.staging.insert(admission.view, owned);
        let mut profile = self.profile.borrow_mut();
        profile.upload_backlog_bytes = admission.backlog_bytes;
        profile.staged_bytes = admission.staged_bytes;
        profile.candidate_ready = false;
        Ok(())
    }
}

#[derive(Default)]
pub(super) struct CoverBindings {
    graph: Option<crate::resources::registry::ResourceKey>,
    meshes: HashSet<crate::resources::registry::ResourceKey>,
    materials: HashSet<[u64; 4]>,
    resources: Vec<crate::resources::registry::ResourceKey>,
}
impl Renderer {
    pub(super) fn retain_cover_bindings(&mut self, frame: &Frame) -> Result<(), String> {
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        let mut bindings = CoverBindings::default();
        // Transfer native references before Dart's frame leases end. Closing a
        // Dart owner never waits for a later frame to replace this cover.
        let result = (|| {
            let state = self.state.as_mut().unwrap();
            if let Some(graph) = frame.graph {
                state
                    .graphs
                    .retain_cover(graph)
                    .map_err(|e| e.to_string())?;
                bindings.graph = Some(graph);
            }
            for key in frame
                .meshes
                .iter()
                .filter_map(|m| m.shader)
                .collect::<HashSet<_>>()
            {
                state
                    .graphs
                    .meshes
                    .retain_cover(key)
                    .map_err(|e| e.to_string())?;
                bindings.meshes.insert(key);
            }
            for key in frame
                .meshes
                .iter()
                .filter_map(|m| m.material_shader)
                .chain(frame.settings.effects.iter().copied())
                .collect::<HashSet<_>>()
            {
                state
                    .graphs
                    .materials
                    .retain(key)
                    .map_err(|e| e.to_string())?;
                bindings.materials.insert(key);
            }
            let mut resources = vec![];
            if let Some(environment) = &frame.environment {
                resources.extend(environment.textures);
            }
            if let Some(environment) = &frame.settings.environment {
                resources.extend(environment.keys.iter().map(|k| {
                    crate::resources::registry::ResourceKey {
                        renderer: k[0],
                        device_generation: k[1],
                        slot: k[2],
                        slot_generation: k[3],
                    }
                }));
            }
            state
                .resources
                .retain_graph(&resources)
                .map_err(|e| e.to_string())?;
            bindings.resources = resources;
            Ok(())
        })();
        if let Err(error) = result {
            self.release_cover_bindings(bindings)?;
            return Err(error);
        }
        if let Some(previous) = self.cover_bindings.insert(view, bindings) {
            self.release_cover_bindings(previous)?;
        }
        Ok(())
    }
    pub(super) fn release_cover_bindings(&mut self, bindings: CoverBindings) -> Result<(), String> {
        let state = self.state.as_mut().unwrap();
        if let Some(graph) = bindings.graph {
            state
                .graphs
                .release(
                    &state.device,
                    &mut state.resources,
                    &mut state.shaders,
                    graph,
                )
                .map_err(|e| e.to_string())?;
        }
        for key in bindings.meshes {
            state
                .graphs
                .meshes
                .release(&state.device, &mut state.resources, &mut state.shaders, key)
                .map_err(|e| e.to_string())?;
        }
        for key in bindings.materials {
            state
                .graphs
                .materials
                .release(&state.device, &mut state.resources, &mut state.shaders, key)
                .map_err(|e| e.to_string())?;
        }
        state
            .resources
            .release_graph(&state.device, &bindings.resources)
            .map_err(|e| e.to_string())
    }
}
