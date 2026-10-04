//! Scene submissions are fenced at handoff. Capture and main draws have separate
//! slots because queue writes preceding one submit cannot snapshot pass values.
use super::{Renderer, timing::Profile};
use std::collections::{HashMap, HashSet};

const MAX_VIEWS: usize = 8;
const MAX_BYTES: usize = 64 * 1024 * 1024;
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum UniformKey {
    Mesh(usize, bool),
    Lighting,
    Environment,
    Shadows,
}
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub(super) struct BindingKey(pub usize, pub u8);
struct Uniform {
    buffer: wgpu::Buffer,
    resource: crate::resources::registry::ResourceKey,
    bytes: Vec<u8>,
    used: u64,
}
#[derive(PartialEq, Eq)]
enum Resource {
    Buffer(wgpu::Buffer, u64, Option<wgpu::BufferSize>),
    Texture(wgpu::TextureView),
    Sampler(wgpu::Sampler),
}
struct Binding {
    layout: wgpu::BindGroupLayout,
    resources: Vec<(u32, Resource)>,
    group: wgpu::BindGroup,
    used: u64,
}
#[derive(Default)]
struct View {
    used: u64,
    uniforms: HashMap<UniformKey, Uniform>,
    bindings: HashMap<BindingKey, Binding>,
    textures: HashMap<wgpu::Texture, (wgpu::TextureView, u64)>,
    samplers: HashMap<[u32; 5], (wgpu::Sampler, u64)>,
}
impl View {
    fn bytes(&self) -> usize {
        self.uniforms
            .values()
            .map(|v| v.buffer.size() as usize)
            .sum()
    }
}
#[derive(Default)]
pub(super) struct Cache {
    views: HashMap<u64, View>,
    current: u64,
    epoch: u64,
}
pub(super) struct Plan {
    view: u64,
    evicted: Vec<u64>,
    unused: Vec<UniformKey>,
    specs: Vec<(UniformKey, usize)>,
    pub additional_bytes: u64,
    pub additional_count: usize,
}
impl Cache {
    pub fn plan(&self, frame: &crate::scene::Frame) -> Plan {
        let id = frame.binary.as_ref().map_or(0, |v| v.view);
        let view = self.views.get(&id);
        let specs = specs(frame);
        let needed: HashSet<_> = specs.iter().map(|(key, _)| *key).collect();
        let missing: Vec<_> = specs
            .iter()
            .filter(|(key, _)| view.is_none_or(|v| !v.uniforms.contains_key(key)))
            .collect();
        let mut plan = Plan {
            view: id,
            evicted: Vec::new(),
            unused: view
                .into_iter()
                .flat_map(|v| v.uniforms.keys().copied())
                .filter(|key| !needed.contains(key))
                .collect(),
            additional_bytes: missing.iter().map(|(_, size)| *size as u64).sum(),
            additional_count: missing.len(),
            specs,
        };
        let candidate_bytes: usize = plan.specs.iter().map(|(_, size)| *size).sum();
        while self.views.len() - plan.evicted.len() + usize::from(view.is_none()) > MAX_VIEWS
            || self
                .views
                .iter()
                .filter(|(id, _)| **id != plan.view && !plan.evicted.contains(id))
                .map(|(_, v)| v.bytes())
                .sum::<usize>()
                + candidate_bytes
                > MAX_BYTES
        {
            if !self.reclaim_older_view(&mut plan) {
                break;
            }
        }
        plan
    }
    pub fn reclaim_older_view(&self, plan: &mut Plan) -> bool {
        let oldest = self
            .views
            .iter()
            .filter(|(id, _)| **id != plan.view && !plan.evicted.contains(id))
            .min_by_key(|(_, v)| v.used)
            .map(|(id, _)| *id);
        if let Some(oldest) = oldest {
            plan.evicted.push(oldest);
            true
        } else {
            false
        }
    }
    pub fn reclaimed_keys(&self, plan: &Plan) -> Vec<crate::resources::registry::ResourceKey> {
        plan.evicted
            .iter()
            .flat_map(|id| self.views[id].uniforms.values().map(|u| u.resource))
            .chain(
                plan.unused
                    .iter()
                    .map(|key| self.views[&plan.view].uniforms[key].resource),
            )
            .collect()
    }
    pub fn begin(&mut self, plan: &Plan) -> Vec<crate::resources::registry::ResourceKey> {
        // Commit the already admitted plan. Registry retirement checks serials.
        self.epoch += 1;
        self.current = plan.view;
        let retired = plan
            .evicted
            .iter()
            .flat_map(|id| self.remove(*id))
            .collect();
        self.views.entry(plan.view).or_default().used = self.epoch;
        retired
    }
    pub fn remove(&mut self, view: u64) -> Vec<crate::resources::registry::ResourceKey> {
        self.views
            .remove(&view)
            .into_iter()
            .flat_map(|v| v.uniforms.into_values().map(|u| u.resource))
            .collect()
    }
    pub fn clear(&mut self) -> Vec<crate::resources::registry::ResourceKey> {
        self.views
            .drain()
            .flat_map(|(_, v)| v.uniforms.into_values().map(|u| u.resource))
            .collect()
    }
    pub fn keys(&self) -> Vec<crate::resources::registry::ResourceKey> {
        self.views
            .get(&self.current)
            .into_iter()
            .flat_map(|v| v.uniforms.values().map(|u| u.resource))
            .collect()
    }
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        resources: &mut crate::resources::ResourceStore,
        specs: &[(UniformKey, usize)],
        profile: &mut Profile,
    ) -> Result<(), String> {
        let view = self.views.get_mut(&self.current).unwrap();
        let needed: HashSet<_> = specs.iter().map(|(key, _)| *key).collect();
        let unused: Vec<_> = view
            .uniforms
            .keys()
            .copied()
            .filter(|k| !needed.contains(k))
            .collect();
        if !unused.is_empty() {
            // Bind groups can retain buffers after their uniform slot is removed.
            // Drop these references before releasing their registry ownership.
            let buffers: Vec<_> = unused
                .iter()
                .map(|key| view.uniforms[key].buffer.clone())
                .collect();
            view.bindings.retain(|_, binding| !binding.resources.iter().any(|(_, resource)| matches!(resource, Resource::Buffer(buffer, _, _) if buffers.contains(buffer))));
            for key in unused {
                resources
                    .release_scene_resource(view.uniforms.remove(&key).unwrap().resource)
                    .map_err(|e| e.to_string())?;
            }
            resources
                .poll_completed(device)
                .map_err(|e| e.to_string())?;
        }
        *profile.draw_uniform_reuses.get_or_insert(0) += specs
            .iter()
            .filter(|(key, _)| view.uniforms.contains_key(key))
            .count() as u64;
        let missing: Vec<_> = specs
            .iter()
            .filter(|(key, _)| !view.uniforms.contains_key(key))
            .collect();
        resources
            .check_scene_capacity(
                missing.iter().map(|(_, size)| *size as u64).sum(),
                missing.len(),
            )
            .map_err(|e| e.to_string())?;
        for (key, size) in missing {
            let (resource, buffer) = resources
                .create_draw_uniform(device, *size as u64)
                .map_err(|e| e.to_string())?;
            view.uniforms.insert(
                *key,
                Uniform {
                    buffer,
                    resource,
                    bytes: Vec::new(),
                    used: self.epoch,
                },
            );
            profile.draw_preparation_buffers += 1;
        }
        Ok(())
    }
    pub fn invalidate_layouts(&mut self, layouts: &[wgpu::BindGroupLayout]) {
        for view in self.views.values_mut() {
            view.bindings
                .retain(|_, binding| !layouts.contains(&binding.layout));
        }
    }

    pub fn invalidate_textures(&mut self, textures: &[&wgpu::Texture]) {
        for view in self.views.values_mut() {
            // Removing the whole binding releases both the comparison handles
            // and the bind group that owns the same GPU texture references.
            view.bindings.retain(|_, binding| {
                !binding.resources.iter().any(|(_, resource)| {
                    matches!(resource, Resource::Texture(view) if textures.contains(&view.texture()))
                })
            });
            view.textures
                .retain(|texture, _| !textures.contains(&texture));
        }
    }
    #[cfg(test)]
    pub fn references_texture(&self, texture: &wgpu::Texture) -> bool {
        self.views.values().any(|view| {
            view.textures.contains_key(texture) || view.bindings.values().any(|binding| binding.resources.iter().any(|(_, resource)| matches!(resource, Resource::Texture(view) if view.texture() == texture)))
        })
    }
    pub fn finish(&mut self, profile: &mut Profile) {
        if let Some(view) = self.views.get_mut(&self.current) {
            view.bindings.retain(|_, v| v.used == self.epoch);
            view.textures.retain(|_, v| v.1 == self.epoch);
            view.samplers.retain(|_, v| v.1 == self.epoch);
        }
        self.snapshot(profile);
    }
    pub fn snapshot(&self, profile: &mut Profile) {
        profile.draw_cache_entries = Some(
            self.views
                .values()
                .map(|v| v.uniforms.len() + v.bindings.len() + v.textures.len() + v.samplers.len())
                .sum::<usize>() as u64,
        );
        profile.draw_cache_uniform_bytes =
            Some(self.views.values().map(View::bytes).sum::<usize>() as u64);
    }
    pub fn uniform(
        &mut self,
        queue: &wgpu::Queue,
        key: UniformKey,
        bytes: &[u8],
        profile: &mut Profile,
    ) -> wgpu::Buffer {
        let view = self
            .views
            .get_mut(&self.current)
            .expect("draw cache frame started");
        let uniform = view
            .uniforms
            .get_mut(&key)
            .expect("uniform slot prepared before encoding");
        assert_eq!(uniform.buffer.size(), bytes.len() as u64);
        uniform.used = self.epoch;
        let range = dirty_range(&uniform.bytes, bytes);
        if let Some(range) = range {
            queue.write_buffer(&uniform.buffer, range.start as u64, &bytes[range.clone()]);
            *profile.draw_uniform_write_calls.get_or_insert(0) += 1;
            *profile.draw_uniform_write_bytes.get_or_insert(0) += range.len() as u64;
            uniform.bytes.clear();
            uniform.bytes.extend_from_slice(bytes);
        } else {
            *profile.draw_uniform_skipped_writes.get_or_insert(0) += 1;
        }
        uniform.buffer.clone()
    }
    pub fn binding(
        &mut self,
        device: &wgpu::Device,
        key: BindingKey,
        layout: &wgpu::BindGroupLayout,
        entries: &[wgpu::BindGroupEntry<'_>],
        profile: &mut Profile,
    ) -> wgpu::BindGroup {
        let resources = entries
            .iter()
            .map(|entry| {
                (
                    entry.binding,
                    match &entry.resource {
                        wgpu::BindingResource::Buffer(v) => {
                            Resource::Buffer(v.buffer.clone(), v.offset, v.size)
                        }
                        wgpu::BindingResource::TextureView(v) => Resource::Texture((*v).clone()),
                        wgpu::BindingResource::Sampler(v) => Resource::Sampler((*v).clone()),
                        _ => unreachable!("scene draw bindings do not use arrays"),
                    },
                )
            })
            .collect::<Vec<_>>();
        let view = self
            .views
            .get_mut(&self.current)
            .expect("draw cache frame started");
        if let Some(binding) = view.bindings.get_mut(&key)
            && binding.layout == *layout
            && binding.resources == resources
        {
            binding.used = self.epoch;
            *profile.draw_cache_reuses.get_or_insert(0) += 1;
            return binding.group.clone();
        }
        profile.draw_preparation_bind_groups += 1;
        let group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("retained draw binding"),
            layout,
            entries,
        });
        view.bindings.insert(
            key,
            Binding {
                layout: layout.clone(),
                resources,
                group: group.clone(),
                used: self.epoch,
            },
        );
        group
    }
    pub fn texture(&mut self, texture: &wgpu::Texture) -> wgpu::TextureView {
        let view = self
            .views
            .get_mut(&self.current)
            .expect("draw cache frame started");
        let entry = view
            .textures
            .entry(texture.clone())
            .or_insert_with(|| (texture.create_view(&Default::default()), self.epoch));
        entry.1 = self.epoch;
        entry.0.clone()
    }
    pub fn sampler(
        &mut self,
        device: &wgpu::Device,
        key: [u32; 5],
        descriptor: &wgpu::SamplerDescriptor<'_>,
    ) -> wgpu::Sampler {
        let view = self
            .views
            .get_mut(&self.current)
            .expect("draw cache frame started");
        let entry = view
            .samplers
            .entry(key)
            .or_insert_with(|| (device.create_sampler(descriptor), self.epoch));
        entry.1 = self.epoch;
        entry.0.clone()
    }
}
// Queue write offsets and lengths must be multiples of COPY_BUFFER_ALIGNMENT.
// One enclosing dirty range avoids many native staging allocations for a camera edit.
fn dirty_range(old: &[u8], new: &[u8]) -> Option<std::ops::Range<usize>> {
    assert_eq!(new.len() % 4, 0);
    if old.len() != new.len() {
        return Some(0..new.len());
    }
    let first = old.iter().zip(new).position(|(a, b)| a != b)?;
    let last = old.iter().zip(new).rposition(|(a, b)| a != b).unwrap();
    Some(first / 4 * 4..(last + 4) / 4 * 4)
}
fn specs(frame: &crate::scene::Frame) -> Vec<(UniformKey, usize)> {
    use UniformKey::*;
    let capture = frame
        .meshes
        .iter()
        .any(|m| m.color_visible && m.transmissive());
    let mut specs = Vec::with_capacity(frame.meshes.len() * 2 + 3);
    if frame.meshes.iter().any(|m| m.pbr.is_some()) {
        specs.extend([
            (Environment, super::environment::UNIFORM_BYTES),
            (Shadows, super::shadows::UNIFORM_BYTES),
            (
                Lighting,
                std::mem::size_of::<crate::lighting::LightingUniform>(),
            ),
        ]);
    }
    for (index, mesh) in frame
        .meshes
        .iter()
        .enumerate()
        .filter(|(_, m)| m.color_visible)
    {
        specs.push((Mesh(index, false), std::mem::size_of::<super::Uniforms>()));
        if capture && !mesh.transmissive() && mesh.alpha_mode != 2 {
            specs.push((Mesh(index, true), std::mem::size_of::<super::Uniforms>()));
        }
    }
    specs
}
impl Renderer {
    pub(super) fn begin_draw_cache(&mut self, plan: Plan) -> Result<(), String> {
        let state = self.state.as_mut().unwrap();
        let retired = state.draw_cache.borrow_mut().begin(&plan);
        for key in retired {
            state
                .resources
                .release_scene_resource(key)
                .map_err(|e| e.to_string())?;
        }
        state
            .resources
            .poll_completed(&state.device)
            .map_err(|e| e.to_string())?;
        let mut profile = state.profile.borrow_mut();
        profile.draw_cache_reuses = Some(0);
        profile.draw_uniform_reuses = Some(0);
        profile.draw_uniform_write_calls = Some(0);
        profile.draw_uniform_write_bytes = Some(0);
        profile.draw_uniform_skipped_writes = Some(0);
        state.draw_cache.borrow_mut().prepare(
            &state.device,
            &mut state.resources,
            &plan.specs,
            &mut profile,
        )
    }
    pub(super) fn clear_draw_cache(&mut self) {
        let keys = self.draw_cache.borrow_mut().clear();
        for key in keys {
            let _ = self.resources.release_scene_resource(key);
        }
    }
    pub(super) fn draw_uniform(&self, key: UniformKey, bytes: &[u8]) -> wgpu::Buffer {
        self.draw_cache.borrow_mut().uniform(
            &self.queue,
            key,
            bytes,
            &mut self.profile.borrow_mut(),
        )
    }
    pub(super) fn draw_binding(
        &self,
        key: BindingKey,
        layout: &wgpu::BindGroupLayout,
        entries: &[wgpu::BindGroupEntry<'_>],
    ) -> wgpu::BindGroup {
        self.draw_cache.borrow_mut().binding(
            &self.device,
            key,
            layout,
            entries,
            &mut self.profile.borrow_mut(),
        )
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn dirty_bytes_preserve_alignment_and_skip_unchanged_data() {
        assert_eq!(dirty_range(&[0; 12], &[0; 12]), None);
        let mut bytes = [0; 12];
        bytes[5] = 1;
        assert_eq!(dirty_range(&[0; 12], &bytes), Some(4..8));
        bytes[11] = 1;
        assert_eq!(dirty_range(&[0; 12], &bytes), Some(4..12));
        assert_eq!(dirty_range(&[], &bytes), Some(0..12));
    }
}
