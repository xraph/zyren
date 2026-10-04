mod encode;
mod pipelines;
mod storage;
#[cfg(test)]
mod tests;
use super::Renderer;
use crate::{
    scene::{Frame, Mesh},
    temporal::{MAX_BYTES, TemporalInput},
};
use pipelines::{MotionKey, Pipelines};
use std::collections::HashMap;

#[derive(Clone)]
struct PreviousMesh {
    logical_geometry: u64,
    mesh: Mesh,
    vertices: wgpu::Buffer,
    source: Option<wgpu::Buffer>,
    pose: Option<wgpu::Buffer>,
    instances: Option<wgpu::Buffer>,
}
impl PreviousMesh {
    fn bytes(&self) -> u64 {
        self.vertices.size()
            + [&self.source, &self.pose, &self.instances]
                .into_iter()
                .flatten()
                .map(|b| b.size())
                .sum::<u64>()
    }
}
struct Snapshot {
    input: TemporalInput,
    vp: [f32; 16],
    unjittered_vp: [f32; 16],
    color: wgpu::Texture,
    depth: wgpu::Texture,
    meshes: HashMap<u64, PreviousMesh>,
    frame: u32,
    phase: u32,
}
impl Snapshot {
    fn bytes(&self) -> u64 {
        u64::from(self.color.width()) * u64::from(self.color.height()) * 12
            + self.meshes.values().map(PreviousMesh::bytes).sum::<u64>()
    }
}
struct History {
    current: Snapshot,
    spare: Option<Snapshot>,
}
impl History {
    fn bytes(&self) -> u64 {
        self.current.bytes() + self.spare.as_ref().map_or(0, Snapshot::bytes)
    }
}
struct Working {
    color: wgpu::Texture,
    depth: wgpu::Texture,
    motion: wgpu::Texture,
}
impl Working {
    fn bytes(&self) -> u64 {
        u64::from(self.color.width()) * u64::from(self.color.height()) * 28
    }
}
struct Pending {
    view: u64,
    candidate: Snapshot,
    valid: bool,
    copies: Vec<(wgpu::Buffer, wgpu::Buffer)>,
}
#[derive(Default)]
pub(super) struct System {
    views: HashMap<u64, History>,
    working: Option<Working>,
    pipelines: Option<Pipelines>,
    pending: Option<Pending>,
}
impl System {
    pub fn remove(&mut self, view: u64) {
        self.views.remove(&view);
        if self.pending.as_ref().is_some_and(|p| p.view == view) {
            self.pending = None;
        }
        if self.views.is_empty() && self.pending.is_none() {
            self.working = None;
        }
    }
    pub fn bytes(&self) -> u64 {
        self.views.values().map(History::bytes).sum::<u64>()
            + self.working.as_ref().map_or(0, Working::bytes)
    }
    pub fn vp(&self, frame: &Frame) -> [f32; 16] {
        if frame.temporal.is_some() {
            self.pending
                .as_ref()
                .expect("prepared temporal frame")
                .candidate
                .vp
        } else {
            frame.view_projection
        }
    }
    pub fn accept(&mut self) {
        if let Some(pending) = self.pending.take() {
            let old = self.views.remove(&pending.view);
            self.views.insert(
                pending.view,
                History {
                    current: pending.candidate,
                    spare: old.map(|h| h.current),
                },
            );
        }
    }
}
impl Renderer {
    pub fn temporal_stats(&self) -> (u64, usize) {
        (self.temporal.bytes(), self.temporal.views.len())
    }
    pub fn temporal_resource_bytes(&self) -> u64 {
        self.temporal.bytes()
    }
    pub(super) fn check_temporal(&mut self, frame: &Frame, size: [u32; 2]) -> Result<(), String> {
        self.temporal.pending = None;
        let Some(input) = &frame.temporal else {
            return Ok(());
        };
        input.validate(frame.meshes.len())?;
        if frame.sample_count() != 1 || frame.color_pipeline.is_none() || frame.binary.is_none() {
            return Err("Temporal AA requires a binary scene view and single-sample HDR".into());
        }
        if frame
            .meshes
            .iter()
            .any(|m| m.shader.is_some() || m.material_shader.is_some() || m.primitive_kind != 0)
        {
            return Err("Temporal AA currently requires built-in triangle materials".into());
        }
        let view = frame.binary.as_ref().unwrap().view;
        let prior = self.temporal.views.get(&view);
        let spare = prior.and_then(|h| h.spare.as_ref());
        let pixels = u64::from(size[0]) * u64::from(size[1]);
        if pixels * 16 > crate::resources::upload::MAX_BYTES {
            return Err("Temporal motion attachment exceeds 64 MiB".into());
        }
        let mut extra =
            if spare.is_some_and(|s| s.color.width() == size[0] && s.color.height() == size[1]) {
                0
            } else {
                pixels * 12
            };
        for (mesh, identity) in frame.meshes.iter().zip(&input.identities) {
            let geometry = frame
                .geometries
                .iter()
                .find(|g| g.id == mesh.geometry)
                .or_else(|| {
                    self.geometries
                        .get(&mesh.geometry)
                        .map(|g| g.recipe.as_ref())
                })
                .ok_or("temporal geometry not resident")?;
            let pose = if mesh.pose == 0 {
                None
            } else {
                Some(
                    frame
                        .poses
                        .iter()
                        .find(|p| p.id == mesh.pose)
                        .or_else(|| self.poses.get(&mesh.pose).map(|p| p.recipe.as_ref()))
                        .ok_or("temporal pose not resident")?,
                )
            };
            let instances = if mesh.instances == 0 {
                None
            } else {
                Some(
                    frame
                        .instances
                        .iter()
                        .find(|i| i.id == mesh.instances)
                        .or_else(|| {
                            self.instances
                                .get(&mesh.instances)
                                .map(|i| i.recipe.as_ref())
                        })
                        .ok_or("temporal instances not resident")?,
                )
            };
            let sizes = [
                geometry.positions.len() as u64 * 24,
                geometry.deformation_bytes() as u64,
                pose.map_or(0, |p| p.byte_length() as u64),
                instances.map_or(0, |i| i.byte_length() as u64),
            ];
            let old = spare.and_then(|s| s.meshes.get(&identity[0]));
            let reusable = [
                old.map(|m| &m.vertices),
                old.and_then(|m| m.source.as_ref()),
                old.and_then(|m| m.pose.as_ref()),
                old.and_then(|m| m.instances.as_ref()),
            ];
            for (bytes, old) in sizes.into_iter().zip(reusable) {
                if bytes > 0 && old.is_none_or(|b| b.size() != bytes) {
                    extra += bytes;
                }
            }
        }
        let working = pixels * 28;
        let old_working = self.temporal.working.as_ref().map_or(0, Working::bytes);
        let total = self.temporal.bytes() - old_working + working + extra;
        let view_bytes = prior.map_or(0, History::bytes) + working + extra;
        if total > MAX_BYTES || view_bytes > input.max_bytes {
            return Err("Temporal history and replacement overlap exceed the byte budget; reduce render scale or scene size".into());
        }
        Ok(())
    }
    pub(super) fn reject_temporal_preparation(&mut self) {
        self.temporal.pending = None;
    }
    pub(super) fn prepare_temporal(&mut self, frame: &Frame, size: [u32; 2]) -> Result<(), String> {
        self.temporal.pending = None;
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        let Some(input) = &frame.temporal else {
            self.temporal.remove(view);
            return Ok(());
        };
        let validation = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = self.device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = self.device.push_error_scope(wgpu::ErrorFilter::Internal);
        let result = (|| -> Result<(), String> {
            let state = self.state.as_mut().unwrap();
            let system = &mut state.temporal;
            if system.pipelines.is_none() {
                system.pipelines = Some(Pipelines::new(&state.device, &state.queue));
            }
            for mesh in &frame.meshes {
                system
                    .pipelines
                    .as_mut()
                    .unwrap()
                    .prepare(&state.device, MotionKey::new(mesh));
            }
            storage::working(&state.device, &mut system.working, size);
            let history = system.views.get(&view);
            let previous = history.map(|h| &h.current);
            let spare = history.and_then(|h| h.spare.as_ref());
            let valid = previous.is_some_and(|p| {
                p.color.width() == size[0]
                    && p.color.height() == size[1]
                    && !input.camera_cut(&p.input)
            });
            let phase = if valid {
                previous.unwrap().phase.wrapping_add(1) % 8
            } else {
                0
            };
            let color = storage::texture(
                &state.device,
                spare.map(|s| &s.color),
                size,
                wgpu::TextureFormat::Rgba16Float,
            );
            let depth = storage::texture(
                &state.device,
                spare.map(|s| &s.depth),
                size,
                wgpu::TextureFormat::R32Float,
            );
            let mut copies = Vec::new();
            let mut meshes = HashMap::new();
            for (mesh, identity) in frame.meshes.iter().zip(&input.identities) {
                let geometry = &state.geometries[&mesh.geometry];
                let vertices = state.resources.geometry(geometry.key).0;
                let source = state.resources.geometry_deformation(geometry.key);
                let pose = if mesh.pose == 0 {
                    None
                } else {
                    Some(
                        state
                            .resources
                            .graph_buffer(state.poses[&mesh.pose].key)
                            .map_err(|e| e.to_string())?,
                    )
                };
                let instances = if mesh.instances == 0 {
                    None
                } else {
                    Some(
                        state
                            .resources
                            .graph_buffer(state.instances[&mesh.instances].key)
                            .map_err(|e| e.to_string())?,
                    )
                };
                let old = spare.and_then(|s| s.meshes.get(&identity[0]));
                let saved = PreviousMesh {
                    logical_geometry: identity[1],
                    mesh: mesh.clone(),
                    vertices: storage::buffer(
                        &state.device,
                        vertices,
                        old.map(|m| &m.vertices),
                        wgpu::BufferUsages::VERTEX,
                        &mut copies,
                    ),
                    source: source.map(|b| {
                        storage::buffer(
                            &state.device,
                            b,
                            old.and_then(|m| m.source.as_ref()),
                            wgpu::BufferUsages::STORAGE,
                            &mut copies,
                        )
                    }),
                    pose: pose.as_ref().map(|b| {
                        storage::buffer(
                            &state.device,
                            b,
                            old.and_then(|m| m.pose.as_ref()),
                            wgpu::BufferUsages::STORAGE,
                            &mut copies,
                        )
                    }),
                    instances: instances.as_ref().map(|b| {
                        storage::buffer(
                            &state.device,
                            b,
                            old.and_then(|m| m.instances.as_ref()),
                            wgpu::BufferUsages::VERTEX,
                            &mut copies,
                        )
                    }),
                };
                meshes.insert(identity[0], saved);
            }
            system.pending = Some(Pending {
                view,
                valid,
                copies,
                candidate: Snapshot {
                    input: input.clone(),
                    unjittered_vp: frame.view_projection,
                    vp: crate::temporal::jitter(frame.view_projection, size, phase),
                    color,
                    depth,
                    meshes,
                    frame: if valid {
                        previous.unwrap().frame.saturating_add(1)
                    } else {
                        1
                    },
                    phase,
                },
            });
            Ok(())
        })();
        let error = pollster::block_on(internal.pop())
            .or(pollster::block_on(memory.pop()))
            .or(pollster::block_on(validation.pop()));
        if let Some(error) = error {
            self.temporal.pending = None;
            return Err(error.to_string());
        }
        if result.is_err() {
            self.temporal.pending = None;
        }
        result
    }
}
