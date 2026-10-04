use super::*;

impl Renderer {
    fn preparation_keys(&self) -> Vec<crate::resources::registry::ResourceKey> {
        self.geometries
            .values()
            .map(|v| v.key)
            .chain(self.instances.values().map(|v| v.key))
            .chain(self.textures.values().map(|v| v.key))
            .chain(self.poses.values().map(|v| v.key))
            .chain(self.draw_cache.borrow().all_keys())
            .chain(
                self.batches
                    .key
                    .filter(|key| self.resources.batch_is_live(*key)),
            )
            .collect()
    }

    pub(super) fn prepare_transaction<T>(
        &mut self,
        frame: &Frame,
        format: wgpu::TextureFormat,
        action: impl FnOnce(&mut Self) -> Result<T, String>,
    ) -> Result<T, String> {
        let warm = frame.temporal.is_none()
            && frame.admission.is_none()
            && self.accepted_preparation.as_ref() == Some(frame)
            && self.batches.ready_for(frame)
            && self
                .draw_cache
                .borrow()
                .plan(frame, |key| self.resources.scene_uniform_recyclable(key))
                .unchanged()
            && frame.meshes.iter().all(|m| {
                self.geometries.contains_key(&m.geometry)
                    && (m.instances == 0 || self.instances.contains_key(&m.instances))
                    && (m.pose == 0 || self.poses.contains_key(&m.pose))
            });
        if warm {
            // Shared pipeline churn or a changed cap must reject before cache writes.
            self.prepare_pipelines(frame, format)?;
            return action(self);
        }
        self.accepted_preparation = None;
        let keys = self.preparation_keys();
        for key in &keys {
            self.resources
                .retain_scene_resource(*key)
                .map_err(|e| e.to_string())?;
        }
        let geometries = self.geometries.clone();
        let instances = self.instances.clone();
        let textures = self.textures.clone();
        let poses = self.poses.clone();
        let staging = self.staging.clone();
        let cache = self.draw_cache.borrow().clone();
        let batches = self.batches.clone();
        self.resources.begin_scene_patches();
        self.draw_cache.borrow_mut().defer_writes();
        match action(self) {
            Ok(value) => {
                let state = self.state.as_mut().unwrap();
                let submission = state
                    .resources
                    .accept_scene_patches(&state.device, &state.queue)
                    .map_err(|e| {
                        state.failure = Some(e.to_string());
                        e.to_string()
                    });
                if submission.is_ok() {
                    state.draw_cache.borrow_mut().submit_writes(&state.queue);
                } else {
                    state.draw_cache.borrow_mut().discard_writes();
                }
                for key in keys {
                    state
                        .resources
                        .release_scene_resource(key)
                        .map_err(|e| e.to_string())?;
                }
                state.resources.register_batch(state.batches.key);
                submission?;
                self.accepted_preparation = (frame.geometries.is_empty()
                    && frame.instances.is_empty()
                    && frame.textures.is_empty()
                    && frame.poses.is_empty()
                    && frame.geometry_patches.is_empty()
                    && frame.instance_patches.is_empty()
                    && frame.admission.is_none())
                .then(|| frame.clone());
                Ok(value)
            }
            Err(error) => {
                self.resources.reject_scene_patches();
                let candidates = self.preparation_keys();
                self.geometries = geometries;
                self.instances = instances;
                self.textures = textures;
                self.poses = poses;
                self.staging = staging;
                *self.draw_cache.borrow_mut() = cache;
                self.batches = batches;
                self.reject_temporal_preparation();
                for key in candidates {
                    self.resources
                        .release_scene_resource(key)
                        .map_err(|e| e.to_string())?;
                }
                let state = self.state.as_mut().unwrap();
                state.resources.register_batch(state.batches.key);
                state
                    .resources
                    .poll_completed(&state.device)
                    .map_err(|e| e.to_string())?;
                Err(error)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a native Metal, Vulkan or DX12 device"]
    fn rejected_dynamic_frame_preserves_bytes_keys_and_retry() {
        for shared in [false, true] {
            let mut renderer = pollster::block_on(Renderer::new()).unwrap();
            let mut frame: Frame = serde_json::from_value(serde_json::json!({
                "version":1,"view_projection":Mat4::IDENTITY.to_cols_array(),"background":[0,0,0],"light_direction":[0,0,1],"ambient":0,
                "geometries":[{"id":1,"positions":[[-0.5,-0.5,0.5],[0.5,-0.5,0.5],[0,0.5,0.5]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
                "meshes":[{"geometry":1,"model":Mat4::IDENTITY.to_cols_array(),"color":[1,0,0],"unlit":true}]
            })).unwrap();
            frame.instances = vec![crate::instances::Instances {
                id: 1,
                transforms: vec![Mat4::IDENTITY.to_cols_array()],
                colors: vec![[1.; 3]],
            }];
            frame.meshes[0].instances = 1;
            frame.binary = Some(crate::scene_packet::ViewState {
                view: 1,
                revision: 1,
                retained: HashSet::from([1]),
                retained_instances: HashSet::from([1]),
                retained_poses: HashSet::new(),
                retained_textures: HashSet::new(),
                meshes: vec![],
            });
            let expected = renderer.render(&frame, 41, 41).unwrap();
            if shared {
                let mut other = frame.clone();
                other.binary.as_mut().unwrap().view = 2;
                renderer.render(&other, 41, 41).unwrap();
            }
            let base_geometry = renderer.geometries[&1].key;
            let base_instances = renderer.instances[&1].key;
            let baseline = renderer.scene_resource_stats().0;
            let mut changed = frame.clone();
            let patch = crate::scene::GeometryPatch {
                id: 2,
                base: 1,
                ranges: vec![crate::geometry_update::AttributeRange {
                    semantic: 0,
                    first: 2,
                    values: vec![0.3, 0.7, 0.5],
                }],
            };
            changed.geometries = vec![patch.apply(&frame.geometries[0]).unwrap()];
            changed.geometry_patches = vec![patch];
            changed.instances[0].id = 2;
            changed.instances[0].transforms[0] =
                Mat4::from_translation(glam::Vec3::new(0.25, 0., 0.)).to_cols_array();
            changed.instance_patches = vec![crate::instances::InstancePatch {
                id: 2,
                base: 1,
                ranges: vec![crate::instances::InstanceRange {
                    first: 0,
                    transforms: changed.instances[0].transforms.clone(),
                    colors: vec![[1.; 3]],
                }],
            }];
            changed.meshes[0].geometry = 2;
            changed.meshes[0].instances = 2;
            let state = changed.binary.as_mut().unwrap();
            state.revision = 2;
            state.retained = HashSet::from([2]);
            state.retained_instances = HashSet::from([2]);
            renderer.pipelines.limits = (0, 128);
            assert!(
                renderer
                    .render(&changed, 41, 41)
                    .unwrap_err()
                    .contains("working set")
            );
            assert_eq!(renderer.geometries[&1].key, base_geometry);
            assert_eq!(renderer.instances[&1].key, base_instances);
            assert!(!renderer.geometries.contains_key(&2));
            assert!(!renderer.instances.contains_key(&2));
            assert_eq!(renderer.views[&1].revision, 1);
            assert_eq!(renderer.scene_resource_stats().0, baseline);
            renderer.pipelines.limits = (512, 128);
            assert_eq!(renderer.render(&frame, 41, 41).unwrap(), expected);
            changed.meshes[0].side = 2;
            renderer.pipelines.fail_creation_after = Some(0);
            assert!(renderer.render(&changed, 41, 41).is_err());
            assert_eq!(renderer.geometries[&1].key, base_geometry);
            assert_eq!(renderer.instances[&1].key, base_instances);
            assert_eq!(renderer.scene_resource_stats().0, baseline);
            let pixels = renderer.render(&changed, 41, 41).unwrap();
            assert_ne!(pixels, expected);
            assert_eq!(renderer.views[&1].revision, 2);
            assert_eq!(renderer.geometries[&2].key == base_geometry, !shared);
            assert_eq!(renderer.instances[&2].key == base_instances, !shared);
            assert_eq!(renderer.profile.borrow().upload_bytes, 24 + 128);
            println!(
                "shared={shared}: rejected candidate cleaned, old pixels exact, corrected revision accepted, dirty bytes=152"
            );
            if !shared {
                let mut warm = changed.clone();
                warm.geometries.clear();
                warm.instances.clear();
                warm.geometry_patches.clear();
                warm.instance_patches.clear();
                let mesh = warm.meshes[0].clone();
                warm.meshes = (0..128)
                    .map(|i| {
                        let mut m = mesh.clone();
                        m.render_order = i;
                        m
                    })
                    .collect();
                renderer.render(&warm, 32, 32).unwrap();
                let mut stationary = Vec::new();
                let mut moving = Vec::new();
                for camera_motion in [false, true] {
                    for i in 0..32 {
                        if camera_motion {
                            warm.view_projection[12] = i as f32 * 0.0001;
                        }
                        renderer.render(&warm, 32, 32).unwrap();
                        let p = renderer.profile.borrow();
                        if camera_motion {
                            moving.push(p.cpu_prepare_ns.unwrap());
                        } else {
                            stationary.push(p.cpu_prepare_ns.unwrap());
                            assert_eq!(p.upload_bytes, 0);
                            assert_eq!(p.draw_uniform_write_bytes, Some(0));
                        }
                    }
                }
                stationary.sort();
                moving.sort();
                println!(
                    "128 meshes, 32 samples: stationary prepare median={}ns, camera-only transactional median={}ns",
                    stationary[16], moving[16]
                );
                let mut peer = warm.clone();
                peer.binary.as_mut().unwrap().view = 2;
                renderer.render(&peer, 32, 32).unwrap();
                renderer.close_scene_view(2).unwrap();
                renderer.render(&warm, 32, 32).unwrap();
                renderer.pipelines.limits = (0, 128);
                assert!(
                    renderer
                        .render(&warm, 32, 32)
                        .unwrap_err()
                        .contains("working set")
                );
                renderer.pipelines.limits = (512, 128);
                renderer.render(&warm, 32, 32).unwrap();
            }
        }
    }
}
