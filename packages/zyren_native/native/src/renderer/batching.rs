use super::{Renderer, draw_order, pipelines::PipelineKey};
use crate::{
    resources::registry::ResourceKey,
    scene::{Frame, Mesh},
};
use glam::{Mat4, Vec3};
use std::{
    collections::{HashMap, HashSet},
    hash::{Hash, Hasher},
};

const WINDOW: usize = 64;
const MAX_TRANSFORMS: usize = 32_768;
const MAX_BATCHES: usize = 256;
const MAX_CACHED_MESHES: usize = 4096;

#[derive(Clone, Copy)]
pub(super) struct Bounds {
    min: Vec3,
    max: Vec3,
}
impl Bounds {
    pub fn geometry(geometry: &crate::scene::Geometry) -> Self {
        geometry.positions.iter().fold(
            Self {
                min: Vec3::splat(f32::INFINITY),
                max: Vec3::splat(f32::NEG_INFINITY),
            },
            |mut b, p| {
                b.min = b.min.min(Vec3::from_array(*p));
                b.max = b.max.max(Vec3::from_array(*p));
                b
            },
        )
    }
    fn project(self, matrix: Mat4) -> Option<Self> {
        let mut result = Self {
            min: Vec3::splat(f32::INFINITY),
            max: Vec3::splat(f32::NEG_INFINITY),
        };
        for x in [self.min.x, self.max.x] {
            for y in [self.min.y, self.max.y] {
                for z in [self.min.z, self.max.z] {
                    let p = matrix * Vec3::new(x, y, z).extend(1.);
                    if !p.is_finite() || p.w <= 1e-5 {
                        return None;
                    }
                    let p = p.truncate() / p.w;
                    if !p.is_finite() {
                        return None;
                    }
                    result.min = result.min.min(p);
                    result.max = result.max.max(p);
                }
            }
        }
        Some(result)
    }
    fn independent(self, other: Self) -> bool {
        // Conservative separation also protects equal-depth fragments and raster edges.
        let margin = Vec3::splat(1e-4);
        (self.max + margin).cmplt(other.min).any() || (other.max + margin).cmplt(self.min).any()
    }
}

#[derive(Clone)]
pub(super) struct Batch {
    pub mesh: Mesh,
    pub range: std::ops::Range<u32>,
}
#[derive(Clone, Default)]
pub(super) struct Batches {
    pub order: Vec<draw_order::Draw>,
    pub leaders: HashMap<usize, Batch>,
    pub skipped: HashSet<usize>,
    pub key: Option<ResourceKey>,
    values: std::sync::Arc<[f32]>,
    view: u64,
    source: std::sync::Arc<[Mesh]>,
    resources: Vec<(ResourceKey, Option<ResourceKey>, Option<ResourceKey>)>,
    projection: [f32; 16],
    settings: (bool, u32, bool),
    environments: Vec<Option<usize>>,
    ready: bool,
}

impl Batches {
    pub(super) fn ready_for(&self, frame: &Frame) -> bool {
        self.ready
            && self.view == frame.binary.as_ref().map_or(0, |v| v.view)
            && self.source.as_ref() == frame.meshes.as_slice()
            && self.projection == frame.view_projection
    }
}

fn eligible(mesh: &Mesh) -> bool {
    let m = Mat4::from_cols_array(&mesh.model);
    mesh.color_visible
        && mesh.alpha_mode != 2
        && mesh.depth_test
        && mesh.writes_depth()
        && mesh.instances == 0
        && mesh.instance_count == 1
        && mesh.pose == 0
        && mesh.shader.is_none()
        && mesh.material_shader.is_none()
        && mesh.primitive_kind == 0
        && !mesh.outlined
        && !mesh.transmissive()
        && mesh.coverage == [0., 1.]
        && m.is_finite()
        && m.inverse().is_finite()
        && m.determinant().abs() >= 1e-20
        && mesh.model[3] == 0.
        && mesh.model[7] == 0.
        && mesh.model[11] == 0.
        && mesh.model[15] == 1.
}
fn material(mesh: &Mesh) -> Mesh {
    let mut m = mesh.clone();
    m.model = Mat4::IDENTITY.to_cols_array();
    m.shadow_world_model = None;
    // Shadow passes still use the original source mesh.
    m.cast_shadow = false;
    m
}

fn order(
    frame: &Frame,
    draws: &mut [draw_order::Draw],
    bounds: &[Option<Bounds>],
    normalized: &[Mesh],
    tangents: impl Fn(u32) -> bool,
) {
    let mut begin = 0;
    let mut ranks = vec![(0_i32, 0_u64, 0_usize); frame.meshes.len()];
    while begin < draws.len() {
        if bounds[draws[begin].mesh].is_none() {
            begin += 1;
            continue;
        }
        let render_order = frame.meshes[draws[begin].mesh].render_order;
        let end = (begin + 1..draws.len().min(begin + WINDOW))
            .find(|&i| {
                bounds[draws[i].mesh].is_none()
                    || frame.meshes[draws[i].mesh].render_order != render_order
            })
            .unwrap_or(draws.len().min(begin + WINDOW));
        let mut materials = Vec::<&Mesh>::new();
        for draw in &draws[begin..end] {
            let mesh = &frame.meshes[draw.mesh];
            let m = &normalized[draw.mesh];
            let rank = materials
                .iter()
                .position(|old| *old == m)
                .unwrap_or_else(|| {
                    materials.push(m);
                    materials.len() - 1
                });
            let mut hash = std::collections::hash_map::DefaultHasher::new();
            PipelineKey::new(
                wgpu::TextureFormat::Rgba8UnormSrgb,
                mesh,
                tangents(mesh.geometry),
                frame.sample_count(),
                false,
            )
            .hash(&mut hash);
            let b = bounds[draw.mesh].unwrap();
            let depth = if frame.settings.reversed_depth() {
                1. - b.max.z
            } else {
                b.min.z
            };
            ranks[draw.mesh] = ((depth * 16.).floor() as i32, hash.finish(), rank);
        }
        // Adjacent swaps cannot cross an ambiguous overlap, even indirectly.
        for i in begin + 1..end {
            let mut j = i;
            while j > begin
                && ranks[draws[j].mesh] < ranks[draws[j - 1].mesh]
                && bounds[draws[j].mesh]
                    .unwrap()
                    .independent(bounds[draws[j - 1].mesh].unwrap())
            {
                draws.swap(j, j - 1);
                j -= 1;
            }
        }
        begin = end;
    }
}

impl Renderer {
    pub(super) fn clear_batches(&mut self) -> Result<(), String> {
        let key = self.batches.key.take();
        self.batches = Batches::default();
        if let Some(key) = key {
            self.resources
                .release_batch(key)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    pub(super) fn close_batches(&mut self, view: u64) -> Result<(), String> {
        if self.batches.view == view {
            self.clear_batches()?;
        }
        Ok(())
    }
    pub(super) fn prepare_batches(&mut self, frame: &Frame) -> Result<(), String> {
        self.profile.borrow_mut().automatic_instance_upload_bytes = Some(0);
        self.profile.borrow_mut().draw_plan_reuses = Some(0);
        let resources: Vec<_> = frame
            .meshes
            .iter()
            .map(|m| {
                (
                    self.geometries[&m.geometry].key,
                    (m.instances != 0).then(|| self.instances[&m.instances].key),
                    (m.pose != 0).then(|| self.poses[&m.pose].key),
                )
            })
            .collect();
        let environments: Vec<_> = (0..frame.meshes.len())
            .map(|index| {
                frame
                    .settings
                    .local_environments
                    .iter()
                    .position(|local| local.meshes.contains(&index))
            })
            .collect();
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        let settings = (
            frame.settings.reversed_depth(),
            frame.sample_count(),
            frame.temporal.is_some(),
        );
        if self.batches.ready
            && self.batches.view == view
            && self.batches.source.as_ref() == frame.meshes.as_slice()
            && self.batches.resources == resources
            && self.batches.projection == frame.view_projection
            && self.batches.settings == settings
            && self.batches.environments == environments
            && self
                .batches
                .key
                .is_none_or(|key| self.resources.batch_is_live(key))
        {
            self.profile.borrow_mut().draw_plan_reuses = Some(1);
            return Ok(());
        }
        let mut draws = draw_order::sorted(
            frame,
            |m| {
                if m.pose == 0 {
                    self.geometries[&m.geometry].center
                } else {
                    self.poses[&m.pose].center
                }
            },
            |id, i| Mat4::from_cols_array(&self.instances[&id].recipe.transforms[i as usize]),
        );
        let vp = Mat4::from_cols_array(&frame.view_projection);
        let bounds: Vec<_> = frame
            .meshes
            .iter()
            .map(|m| {
                (frame.temporal.is_none() && eligible(m))
                    .then(|| {
                        self.geometries[&m.geometry]
                            .bounds
                            .project(vp * Mat4::from_cols_array(&m.model))
                    })
                    .flatten()
            })
            .collect();
        let normalized: Vec<_> = frame.meshes.iter().map(material).collect();
        order(frame, &mut draws, &bounds, &normalized, |id| {
            !self.geometries[&id].recipe.tangents.is_empty()
        });
        let mut candidate = Batches {
            order: draws,
            view,
            source: if frame.meshes.len() <= MAX_CACHED_MESHES {
                frame.meshes.clone().into()
            } else {
                [].into()
            },
            resources: if frame.meshes.len() <= MAX_CACHED_MESHES {
                resources
            } else {
                vec![]
            },
            projection: frame.view_projection,
            settings,
            environments: environments.clone(),
            ready: frame.meshes.len() <= MAX_CACHED_MESHES,
            ..Default::default()
        };
        let mut transforms = Vec::new();
        let mut i = 0;
        while i < candidate.order.len() && candidate.leaders.len() < MAX_BATCHES {
            let first = candidate.order[i].mesh;
            if bounds[first].is_none() {
                i += 1;
                continue;
            }
            let m = &normalized[first];
            let mut end = i + 1;
            while end < candidate.order.len()
                && end - i < WINDOW
                && transforms.len() + end - i < MAX_TRANSFORMS
            {
                let next = candidate.order[end].mesh;
                if bounds[next].is_none()
                    || &normalized[next] != m
                    || environments[next] != environments[first]
                    || (i..end).any(|j| {
                        !bounds[next]
                            .unwrap()
                            .independent(bounds[candidate.order[j].mesh].unwrap())
                    })
                {
                    break;
                }
                end += 1;
            }
            if end - i > 1 {
                let start = transforms.len() as u32;
                for j in i..end {
                    let index = candidate.order[j].mesh;
                    transforms.push(frame.meshes[index].model);
                    if j != i {
                        candidate.skipped.insert(index);
                    }
                }
                candidate.leaders.insert(
                    first,
                    Batch {
                        mesh: m.clone(),
                        range: start..transforms.len() as u32,
                    },
                );
            }
            i = end;
        }
        if transforms.is_empty() {
            self.clear_batches()?;
            self.batches = candidate;
            return Ok(());
        }
        candidate.values = crate::instances::transform_values(&transforms).into();
        if self
            .batches
            .key
            .is_some_and(|key| self.resources.batch_is_live(key))
            && self.batches.values == candidate.values
        {
            candidate.key = self.batches.key.take();
        } else if self
            .resources
            .check_scene_capacity((candidate.values.len() * 4) as u64, 1)
            .is_ok()
        {
            let state = self.state.as_mut().unwrap();
            state.profile.borrow_mut().automatic_instance_upload_bytes =
                Some((candidate.values.len() * 4) as u64);
            candidate.key = Some(
                state
                    .resources
                    .insert_instance_values(&state.device, &candidate.values)
                    .map_err(|e| e.to_string())?,
            );
        } else {
            // Optional acceleration never consumes the space needed by source resources.
            candidate.ready = false;
            candidate.leaders.clear();
            candidate.skipped.clear();
            candidate.values = [].into();
        }
        self.clear_batches()?;
        self.resources.register_batch(candidate.key);
        self.batches = candidate;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn frame() -> Frame {
        serde_json::from_value(serde_json::json!({"version":1,"view_projection":Mat4::IDENTITY.to_cols_array(),"background":[0,0,0],"light_direction":[0,0,1],"ambient":0,"geometries":[{"id":1,"positions":[[-0.1,-0.1,0.4],[0.1,-0.1,0.4],[0,0.1,0.4]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],"meshes":[]})).unwrap()
    }
    #[test]
    fn coarse_near_depth_and_explicit_order_preserve_barriers_and_transparent_instances() {
        let mut f = frame();
        f.meshes = vec![
            Mesh {
                geometry: 1,
                model: Mat4::from_translation(Vec3::new(0., 0., 0.4)).to_cols_array(),
                ..Default::default()
            },
            Mesh {
                geometry: 1,
                ..Default::default()
            },
        ];
        let plan = |f: &Frame| {
            let mut draws = draw_order::sorted(
                f,
                |_| Vec3::new(0., 0., 0.4),
                |_, i| Mat4::from_translation(Vec3::new(0., 0., i as f32 * 0.2)),
            );
            let b = Bounds::geometry(&f.geometries[0]);
            let bounds: Vec<_> = f
                .meshes
                .iter()
                .map(|m| {
                    eligible(m)
                        .then(|| b.project(Mat4::from_cols_array(&m.model)))
                        .flatten()
                })
                .collect();
            order(
                f,
                &mut draws,
                &bounds,
                &f.meshes.iter().map(material).collect::<Vec<_>>(),
                |_| false,
            );
            draws
                .into_iter()
                .map(|d| (d.mesh, d.instances.start))
                .collect::<Vec<_>>()
        };
        assert_eq!(plan(&f), [(1, 0), (0, 0)]);
        f.meshes[0].render_order = -1;
        assert_eq!(plan(&f), [(0, 0), (1, 0)]);
        f.meshes[0].render_order = 0;
        f.meshes[0].depth_test = false;
        assert_eq!(plan(&f), [(0, 0), (1, 0)]);
        for m in &mut f.meshes {
            m.alpha_mode = 2;
            m.depth_test = true;
        }
        f.meshes[1].instances = 1;
        f.meshes[1].instance_count = 2;
        assert_eq!(plan(&f), [(0, 0), (1, 1), (1, 0)]);
        f.settings.depth_strategy = 1;
        assert_eq!(plan(&f), [(1, 0), (1, 1), (0, 0)]);
    }
    #[test]
    #[ignore = "requires a native GPU"]
    fn retained_plan_rechecks_native_geometry_generation() {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let mut f = frame();
        f.meshes = vec![
            Mesh {
                geometry: 1,
                model: Mat4::from_translation(Vec3::new(-0.3, 0., 0.)).to_cols_array(),
                ..Default::default()
            },
            Mesh {
                geometry: 1,
                model: Mat4::from_translation(Vec3::new(0.3, 0., 0.)).to_cols_array(),
                ..Default::default()
            },
        ];
        renderer.render(&f, 41, 41).unwrap();
        f.geometries.clear();
        renderer.render(&f, 41, 41).unwrap();
        assert_eq!(renderer.profile.borrow().draw_plan_reuses, Some(1));
        let old = renderer.geometries.remove(&1).unwrap();
        let mut geometry = (*old.recipe).clone();
        for p in &mut geometry.positions {
            p[0] *= 10.;
        }
        let state = renderer.state.as_mut().unwrap();
        state.resources.release_scene_resource(old.key).unwrap();
        let key = state
            .resources
            .insert_geometry(&state.device, &geometry)
            .unwrap();
        assert_ne!(key, old.key);
        state.geometries.insert(
            1,
            super::super::GpuGeometry {
                key,
                center: draw_order::geometry_center(&geometry),
                bounds: Bounds::geometry(&geometry),
                deformation_bounds: crate::deformation::SourceBounds::new(&geometry),
                recipe: std::sync::Arc::new(geometry),
            },
        );
        renderer.render(&f, 41, 41).unwrap();
        assert_eq!(renderer.profile.borrow().draw_plan_reuses, Some(0));
        assert_eq!(renderer.profile.borrow().opaque_batch_draws, Some(0));
    }
    #[test]
    #[ignore = "requires a native Metal, Vulkan or DX12 device"]
    fn probe_assignments_split_batches_and_invalidate_cached_plan() {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let mut locals = Vec::new();
        for color in [wgpu::Color::RED, wgpu::Color::GREEN] {
            let mut keys = Vec::new();
            for (height, mips) in [(8, 1), (8, 2), (16, 1)] {
                let state = renderer.state.as_mut().unwrap();
                let (key, texture) =
                    state
                        .resources
                        .test_environment_texture(&state.device, height, mips);
                let mut encoder = state.device.create_command_encoder(&Default::default());
                for mip in 0..mips {
                    let view = texture.create_view(&wgpu::TextureViewDescriptor {
                        base_mip_level: mip,
                        mip_level_count: Some(1),
                        ..Default::default()
                    });
                    let _pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                            view: &view,
                            resolve_target: None,
                            depth_slice: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Clear(color),
                                store: wgpu::StoreOp::Store,
                            },
                        })],
                        ..Default::default()
                    });
                }
                state.queue.submit([encoder.finish()]);
                keys.push([
                    key.renderer,
                    key.device_generation,
                    key.slot,
                    key.slot_generation,
                ]);
            }
            locals.push(crate::scene::LocalEnvironment {
                meshes: vec![],
                keys: keys.try_into().unwrap(),
                intensity: 1.,
                rotation: [0., 0., 0., 1.],
            });
        }
        let mut f = frame();
        let mesh:Mesh=serde_json::from_value(serde_json::json!({"geometry":1,"model":Mat4::IDENTITY.to_cols_array(),"color":[1,1,1],"unlit":false,"pbr":{"metallic":0,"roughness":1,"emissive":[0,0,0]}})).unwrap();
        f.meshes = vec![mesh.clone(), mesh];
        for (i, m) in f.meshes.iter_mut().enumerate() {
            m.model = Mat4::from_translation(Vec3::new(if i == 0 { -0.3 } else { 0.3 }, 0., 0.))
                .to_cols_array();
        }
        locals[0].meshes = vec![0, 1];
        f.settings.local_environments = vec![locals[0].clone()];
        renderer.render(&f, 64, 64).unwrap();
        assert_eq!(renderer.profile.borrow().opaque_batch_draws, Some(1));
        f.geometries.clear();
        renderer.render(&f, 64, 64).unwrap();
        assert_eq!(renderer.profile.borrow().draw_plan_reuses, Some(1));
        for two in [false, true] {
            locals[0].meshes = vec![0];
            locals[1].meshes = vec![1];
            f.settings.local_environments = if two {
                locals.clone()
            } else {
                vec![locals[0].clone()]
            };
            let actual = renderer.render(&f, 64, 64).unwrap();
            assert_eq!(renderer.profile.borrow().opaque_batch_draws, Some(0));
            assert_eq!(renderer.profile.borrow().draw_plan_reuses, Some(0));
            f.meshes[1].render_order = 1;
            let expected = renderer.render(&f, 64, 64).unwrap();
            assert_eq!(actual, expected);
            f.meshes[1].render_order = 0;
            println!("two_local={two}: full image equals ordered reference");
        }
    }
}
