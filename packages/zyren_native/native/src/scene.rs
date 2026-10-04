pub use crate::geometry_update::{AttributeRange, GeometryPatch};
use crate::resources::texture_format;
use std::collections::HashSet;

use serde::Deserialize;

pub const MAX_DIMENSION: u32 = 4096;
pub const MAX_VERTICES: usize = 1_000_000;
pub const MAX_INDICES: usize = 3_000_000;
pub const MAX_MESHES: usize = 4096;
pub const MAX_INSTANCES: usize = 65536;

#[derive(Clone, Copy, Default, PartialEq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum IndexFormat {
    Uint16,
    #[default]
    Uint32,
}
impl IndexFormat {
    pub fn bytes(self) -> usize {
        match self {
            Self::Uint16 => 2,
            Self::Uint32 => 4,
        }
    }
    pub fn native(self) -> wgpu::IndexFormat {
        match self {
            Self::Uint16 => wgpu::IndexFormat::Uint16,
            Self::Uint32 => wgpu::IndexFormat::Uint32,
        }
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Geometry {
    pub id: u32,
    #[serde(default)]
    pub topology: u32,
    pub positions: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub indices: Vec<u32>,
    #[serde(default)]
    pub index_format: IndexFormat,
    #[serde(default)]
    pub uv0: Vec<[f32; 2]>,
    #[serde(default)]
    pub uv1: Vec<[f32; 2]>,
    #[serde(default)]
    pub tangents: Vec<[f32; 4]>,
    #[serde(default)]
    pub colors: Vec<[f32; 4]>,
    #[serde(default)]
    pub joints: Vec<[u32; 4]>,
    #[serde(default)]
    pub weights: Vec<[f32; 4]>,
    #[serde(default)]
    pub morphs: Vec<crate::deformation::MorphTarget>,
}

impl Geometry {
    pub fn primitive_count(&self) -> usize {
        match self.topology {
            0 => self.indices.len() / 3,
            1 => self.indices.len() / 2,
            2 => self.indices.len().saturating_sub(1),
            _ => self.indices.len(),
        }
    }
    pub fn byte_length(&self) -> usize {
        if self.topology != 0 {
            return self.primitive_count() * (if self.colors.is_empty() { 120 } else { 248 });
        }
        self.positions.len()
            * (if self.uv0.is_empty() && self.uv1.is_empty() {
                24
            } else {
                40
            })
            + self.indices.len() * self.index_format.bytes()
            + self.tangents.len() * 16
            + self.colors.len() * 16
            + self.deformation_bytes()
    }
    pub fn cpu_byte_length(&self) -> usize {
        (self.positions.len() + self.normals.len()) * 12
            + (self.uv0.len() + self.uv1.len()) * 8
            + self.indices.len() * 4
            + self.tangents.len() * 16
            + self.colors.len() * 16
            + self.deformation_bytes()
    }
    pub fn validate(&self) -> Result<(), String> {
        self.validate_deformation()?;
        if self.topology > 3
            || (self.topology != 0
                && (self.primitive_count() > 250_000
                    || !self.uv0.is_empty()
                    || !self.uv1.is_empty()
                    || !self.tangents.is_empty()))
        {
            return Err("unsupported primitive topology, attributes or expanded budget".into());
        }
        if !self.colors.is_empty()
            && (self.colors.len() != self.positions.len()
                || self
                    .colors
                    .iter()
                    .flatten()
                    .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v)))
        {
            return Err("colors need four finite values in [0,1] per vertex".into());
        }
        if !self.tangents.is_empty()
            && (self.tangents.len() != self.positions.len()
                || self.tangents.iter().any(|t| {
                    let norm = glam::Vec3::new(t[0], t[1], t[2]).length_squared();
                    t.iter().any(|v| !v.is_finite())
                        || !norm.is_finite()
                        || norm < 1e-12
                        || t[3].abs() != 1.
                }))
        {
            return Err("tangents need nonzero finite XYZ and handedness -1 or 1".into());
        }
        for uv in [&self.uv0, &self.uv1] {
            if !uv.is_empty()
                && (uv.len() != self.positions.len() || uv.iter().flatten().any(|v| !v.is_finite()))
            {
                return Err("UV attributes need two finite values per vertex".into());
            }
        }
        if !self.tangents.is_empty()
            && (self.tangents.len() != self.positions.len()
                || self.tangents.iter().any(|v| {
                    v.iter().any(|c| !c.is_finite())
                        || glam::Vec3::new(v[0], v[1], v[2]).length_squared() < 1e-12
                        || (v[3] != -1. && v[3] != 1.)
                }))
        {
            return Err("tangents need a nonzero direction and handedness of +/-1".into());
        }
        if self.positions.is_empty() || self.positions.len() > MAX_VERTICES {
            return Err("geometry vertex count is outside the supported range".into());
        }
        if self.normals.len() != self.positions.len()
            || self.indices.is_empty()
            || self.indices.len() > MAX_INDICES
            || (self.topology == 0 && !self.indices.len().is_multiple_of(3))
            || (self.topology == 1 && !self.indices.len().is_multiple_of(2))
            || (self.topology == 2 && self.indices.len() < 2)
        {
            return Err(
                "geometry needs one normal per vertex and indices matching its topology".into(),
            );
        }
        if self
            .positions
            .iter()
            .chain(&self.normals)
            .flatten()
            .any(|v| !v.is_finite())
            || self
                .normals
                .iter()
                .any(|v| glam::Vec3::from_array(*v).length_squared() < 1e-12)
            || self.indices.iter().any(|i| {
                *i as usize >= self.positions.len()
                    || (self.index_format == IndexFormat::Uint16 && *i > u16::MAX as u32)
            })
        {
            return Err("geometry contains invalid coordinates, normals or indices".into());
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Mesh {
    #[serde(skip)]
    pub environment_slot: usize,
    #[serde(skip)]
    pub scene_inputs: bool,
    #[serde(default)]
    pub shadow_world_model: Option<[f64; 16]>,
    #[serde(skip)]
    pub reversed_depth: bool,
    #[serde(skip)]
    pub outline_pass: bool,
    #[serde(default = "enabled")]
    pub color_visible: bool,
    #[serde(default)]
    pub cast_shadow: bool,
    #[serde(default)]
    pub receive_shadow: bool,
    #[serde(skip)]
    pub shader: Option<crate::resources::registry::ResourceKey>,
    #[serde(skip)]
    pub instances: u32,
    #[serde(skip)]
    pub pose: u32,
    #[serde(skip, default = "one_instance")]
    pub instance_count: u32,
    pub geometry: u32,
    pub model: [f32; 16],
    pub color: [f32; 3],
    pub unlit: bool,
    #[serde(default)]
    pub vertex_colors: bool,
    #[serde(default)]
    pub color_map: Option<ColorMap>,
    #[serde(default)]
    pub pbr: Option<crate::lighting::StandardMaterial>,
    #[serde(default)]
    pub alpha_mode: u32,
    #[serde(default)]
    pub side: u32,
    #[serde(default)]
    pub material_shader: Option<[u64; 4]>,
    #[serde(default = "one")]
    pub opacity: f32,
    #[serde(default = "half")]
    pub alpha_cutoff: f32,
    #[serde(default = "enabled")]
    pub depth_test: bool,
    #[serde(default)]
    pub depth_write: Option<bool>,
    #[serde(default)]
    pub render_order: i32,
    #[serde(default)]
    pub primitive_kind: u32,
    #[serde(default = "one")]
    pub primitive_size: f32,
    #[serde(default)]
    pub size_units: u32,
    #[serde(default)]
    pub point_shape: u32,
    #[serde(default)]
    pub clipping_planes: Vec<[f32; 4]>,
    #[serde(default)]
    pub outlined: bool,
    #[serde(default = "full_coverage")]
    pub coverage: [f32; 2],
}
fn one_instance() -> u32 {
    1
}
fn one() -> f32 {
    1.
}
fn half() -> f32 {
    0.5
}
fn enabled() -> bool {
    true
}
fn full_coverage() -> [f32; 2] {
    [0., 1.]
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct MeshExtension {
    #[serde(default)]
    pub shadow_world_model: Option<[f64; 16]>,
    pub material_shader: Option<[u64; 4]>,
    pub clipping_planes: Vec<[f32; 4]>,
    pub coverage: [f32; 2],
    pub outlined: bool,
    pub normal_scale_y: Option<f32>,
    pub specular_aa: Option<[f32; 2]>,
}
impl Default for Mesh {
    fn default() -> Self {
        Self {
            environment_slot: 0,
            scene_inputs: false,
            shadow_world_model: None,
            reversed_depth: false,
            outline_pass: false,
            color_visible: true,
            cast_shadow: false,
            receive_shadow: false,
            instances: 0,
            pose: 0,
            instance_count: 1,
            geometry: 0,
            shader: None,
            model: glam::Mat4::IDENTITY.to_cols_array(),
            color: [1.; 3],
            unlit: false,
            vertex_colors: false,
            color_map: None,
            pbr: None,
            alpha_mode: 0,
            side: 0,
            material_shader: None,
            opacity: 1.,
            alpha_cutoff: 0.5,
            depth_test: true,
            depth_write: None,
            render_order: 0,
            primitive_kind: 0,
            primitive_size: 1.,
            size_units: 0,
            point_shape: 0,
            clipping_planes: Vec::new(),
            outlined: false,
            coverage: [0., 1.],
        }
    }
}
impl Mesh {
    pub fn requires_opaque_capture(&self) -> bool {
        self.scene_inputs || self.transmissive()
    }
    pub fn transmissive(&self) -> bool {
        self.pbr.as_ref().is_some_and(|p| {
            p.transmission[0] > 0. && (p.metallic < 1. || p.metallic_roughness_map.is_some())
        })
    }

    pub fn anisotropic(&self) -> bool {
        self.pbr
            .as_ref()
            .and_then(|p| p.physical)
            .is_some_and(|p| p[11] > 0.)
    }

    pub fn texture_maps(&self) -> impl Iterator<Item = &ColorMap> {
        self.color_map
            .iter()
            .chain(self.pbr.iter().flat_map(|p| p.maps().into_iter().flatten()))
    }

    pub fn writes_depth(&self) -> bool {
        self.depth_write.unwrap_or(self.alpha_mode != 2)
    }
    pub fn validate_material(&self) -> Result<(), String> {
        if self
            .shadow_world_model
            .is_some_and(|matrix| matrix.iter().any(|v| !v.is_finite()))
        {
            return Err("Invalid shadow world transform".into());
        }
        if self.shader.is_some() && self.material_shader.is_some() {
            return Err("A mesh requires one shader implementation".into());
        }
        if self.shader.is_some() && !self.clipping_planes.is_empty()
            || self.clipping_planes.len() > 6
            || self.clipping_planes.iter().any(|p| {
                p.iter().any(|v| !v.is_finite())
                    || (glam::Vec3::new(p[0], p[1], p[2]).length_squared() - 1.).abs() > 1e-4
            })
        {
            return Err("Invalid clipping planes".into());
        }
        if self.pose != 0 && self.primitive_kind != 0 {
            return Err("deformation requires triangle materials".into());
        }
        if self.instance_count == 0
            || self.instance_count as usize > crate::instances::MAX_INSTANCES
            || (self.instances == 0 && self.instance_count != 1)
            || (self.instances != 0 && self.primitive_kind != 0)
        {
            return Err("instancing requires a triangle material and valid count".into());
        }
        if let Some(pbr) = &self.pbr {
            pbr.validate()?;
            if self.unlit
                || self.primitive_kind != 0
                || self.shader.is_some()
                || self.material_shader.is_some()
            {
                return Err("standard material cannot be unlit, expanded or custom".into());
            }
        }
        if self.side > 2 || (self.primitive_kind != 0 && self.side != 0) {
            return Err("invalid material side".into());
        }
        if self.primitive_kind > 2
            || self.size_units > 1
            || self.point_shape > 1
            || !self.primitive_size.is_finite()
            || self.primitive_size <= 0.
            || self.primitive_size > if self.size_units == 0 { 4096. } else { 1e12 }
            || (self.primitive_kind != 0 && (self.color_map.is_some() || !self.unlit))
        {
            return Err("invalid primitive material".into());
        }
        if self.coverage.iter().any(|v| !v.is_finite())
            || self.coverage[0] < 0.
            || self.coverage[1] > 1.
            || self.coverage[0] > self.coverage[1]
            || ((self.shader.is_some() || self.material_shader.is_some())
                && self.coverage != [0., 1.])
        {
            return Err("invalid or unsupported fragment coverage".into());
        }
        if self.alpha_mode > 2
            || !self.opacity.is_finite()
            || !(0.0..=1.0).contains(&self.opacity)
            || !self.alpha_cutoff.is_finite()
            || self.alpha_cutoff < 0.
        {
            return Err("invalid alpha mode, opacity or cutoff".into());
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ColorMap {
    pub texture: u32,
    pub uv_set: u32,
    pub sampler: [u32; 5],
}
impl ColorMap {
    pub fn validate(&self) -> Result<(), String> {
        if self.uv_set > 1
            || self.sampler[..2].iter().any(|v| *v > 2)
            || self.sampler[2..].iter().any(|v| *v > 1)
        {
            return Err("unsupported UV set or sampler".into());
        }
        Ok(())
    }
}
#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SceneTexture {
    pub id: u32,
    pub width: u32,
    pub height: u32,
    pub format: u32,
    pub levels: Vec<Vec<u8>>,
    #[serde(default)]
    pub mip_generation: u32,
}
impl SceneTexture {
    pub fn mip_count(&self) -> u32 {
        if self.mip_generation == 0 {
            self.levels.len() as u32
        } else {
            32 - self.width.max(self.height).leading_zeros()
        }
    }
    pub fn byte_length(&self) -> usize {
        (0..self.mip_count())
            .map(|m| {
                texture_format::level_bytes(
                    self.format,
                    (self.width >> m).max(1),
                    (self.height >> m).max(1),
                ) as usize
            })
            .sum()
    }
    pub fn upload_byte_length(&self) -> usize {
        self.levels.iter().map(Vec::len).sum()
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.width == 0
            || self.height == 0
            || self.width > 4096
            || self.height > 4096
            || self.format == 2
            || self.format > 8
            || (texture_format::compressed(self.format)
                && (!self.width.is_multiple_of(4)
                    || !self.height.is_multiple_of(4)
                    || self.mip_generation != 0))
            || self.mip_generation > 2
            || (self.mip_generation != 0 && self.levels.len() != 1)
            || self.levels.is_empty()
            || self.levels.len() > (32 - self.width.max(self.height).leading_zeros()) as usize
        {
            return Err("invalid texture extent, format or mip count".into());
        }
        for (mip, level) in self.levels.iter().enumerate() {
            let size = texture_format::level_bytes(
                self.format,
                (self.width >> mip).max(1),
                (self.height >> mip).max(1),
            ) as usize;
            if level.len() != size {
                return Err("texture mip length does not match its extent".into());
            }
        }
        if self.byte_length() > 64 * 1024 * 1024 {
            return Err("texture exceeds byte budget".into());
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EnvironmentMap {
    pub keys: [[u64; 4]; 3],
    pub intensity: f32,
    pub rotation: f32,
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BloomSettings {
    pub intensity: f32,
    pub threshold: f32,
    pub soft_knee: f32,
    pub scatter: f32,
    pub levels: u32,
}
impl BloomSettings {
    fn validate(&self) -> Result<(), String> {
        if !self.intensity.is_finite()
            || !(0.0..=16.).contains(&self.intensity)
            || !self.threshold.is_finite()
            || !(0.0..=65504.).contains(&self.threshold)
            || !self.soft_knee.is_finite()
            || !(0.0..=1.).contains(&self.soft_knee)
            || !self.scatter.is_finite()
            || !(0.0..=1.).contains(&self.scatter)
            || !(1..=6).contains(&self.levels)
        {
            return Err("Invalid bloom parameters".into());
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LocalEnvironment {
    pub meshes: Vec<usize>,
    pub keys: [[u64; 4]; 3],
    pub intensity: f32,
    pub rotation: [f32; 4],
}
impl LocalEnvironment {
    pub fn environment(&self) -> crate::lighting::Environment {
        crate::lighting::Environment {
            textures: self.keys.map(|k| crate::resources::registry::ResourceKey {
                renderer: k[0],
                device_generation: k[1],
                slot: k[2],
                slot_generation: k[3],
            }),
            intensity: self.intensity,
            rotation: self.rotation,
        }
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RenderSettings {
    pub screen_lighting: Option<crate::renderer::screen_lighting::Settings>,
    pub outline: Option<OutlineSettings>,
    pub enabled: bool,
    pub sample_count: u32,
    pub opaque_capture_scale: f32,
    pub depth_strategy: u32,
    pub spatial_antialiasing: u32,
    pub bloom: Option<BloomSettings>,
    pub effects: Vec<[u64; 4]>,
    pub tone_mapping: u32,
    pub exposure: f32,
    pub background_alpha: f32,
    pub history_epoch: u32,
    pub camera_origin: [f64; 3],
    pub shadow_world_lights: Vec<[f64; 4]>,
    pub shadow_world_areas: Vec<[f64; 7]>,
    pub environment: Option<EnvironmentMap>,
    pub local_environments: Vec<LocalEnvironment>,
}
impl Default for RenderSettings {
    fn default() -> Self {
        Self {
            screen_lighting: None,
            enabled: false,
            outline: None,
            sample_count: 1,
            opaque_capture_scale: 1.,
            depth_strategy: 0,
            spatial_antialiasing: 0,
            bloom: None,
            effects: vec![],
            tone_mapping: 0,
            exposure: 1.,
            background_alpha: 1.,
            history_epoch: 0,
            camera_origin: [0.; 3],
            shadow_world_lights: Vec::new(),
            shadow_world_areas: Vec::new(),
            environment: None,
            local_environments: Vec::new(),
        }
    }
}
impl RenderSettings {
    pub fn reversed_depth(&self) -> bool {
        self.depth_strategy == 1
    }
    pub fn depth_clear(&self) -> f32 {
        if self.reversed_depth() { 0. } else { 1. }
    }
    pub fn depth_near(&self) -> f32 {
        if self.reversed_depth() { 1. } else { 0. }
    }
    pub fn validate(&self) -> Result<(), String> {
        if let Some(settings) = &self.screen_lighting {
            settings.validate()?;
        }
        if self.local_environments.len() > 4 {
            return Err("At most four local environments".into());
        }
        let mut selected = std::collections::HashSet::new();
        for local in &self.local_environments {
            local.environment().validate()?;
            for &index in &local.meshes {
                if index >= 4096 || !selected.insert(index) {
                    return Err("Invalid local environment selection".into());
                }
            }
        }
        if self.outline.as_ref().is_some_and(|o| {
            !(1..=8).contains(&o.width)
                || o.color
                    .iter()
                    .any(|v| !v.is_finite() || !(0.0..=1.).contains(v))
        }) {
            return Err("Invalid outline settings".into());
        }
        if self.environment.as_ref().is_some_and(|e| {
            !e.intensity.is_finite()
                || !(0.0..=65504.).contains(&e.intensity)
                || !e.rotation.is_finite()
        }) {
            return Err("Invalid environment parameters".into());
        }
        if let Some(bloom) = &self.bloom {
            bloom.validate()?;
        }
        if !self.opaque_capture_scale.is_finite()
            || !(0.5..=1.).contains(&self.opaque_capture_scale)
            || self.depth_strategy > 1
            || self.spatial_antialiasing > 1
            || ((self.spatial_antialiasing != 0 || self.bloom.is_some()) && !self.enabled)
            || ![1, 4].contains(&self.sample_count)
            || (self.sample_count != 1 && !self.enabled)
            || self.camera_origin.iter().any(|v| !v.is_finite())
            || self.shadow_world_lights.len() > crate::shadows::MAX_SHADOW_LIGHTS
            || self.shadow_world_areas.len() > crate::lighting::MAX_AREAS
            || self.shadow_world_areas.iter().enumerate().any(|(i, area)| {
                area.iter().any(|v| !v.is_finite())
                    || area[0].fract() != 0.
                    || !(crate::lighting::MAX_LIGHTS as f64
                        ..crate::shadows::MAX_SHADOW_LIGHTS as f64)
                        .contains(&area[0])
                    || self.shadow_world_areas[..i]
                        .iter()
                        .any(|prior| prior[0] == area[0])
            })
            || self
                .shadow_world_lights
                .iter()
                .enumerate()
                .any(|(i, light)| {
                    light.iter().any(|v| !v.is_finite())
                        || light[0].fract() != 0.
                        || !(0.0..crate::shadows::MAX_SHADOW_LIGHTS as f64).contains(&light[0])
                        || self.shadow_world_lights[..i]
                            .iter()
                            .any(|prior| prior[0] == light[0])
                })
            || self.effects.len() > 32
            || self.tone_mapping > 6
            || !self.exposure.is_finite()
            || !(0.0..=1e6).contains(&self.exposure)
            || !self.background_alpha.is_finite()
            || !(0.0..=1.).contains(&self.background_alpha)
        {
            return Err("Invalid render settings".into());
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct OutlineSettings {
    pub color: [f32; 4],
    pub width: u32,
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Frame {
    #[serde(skip)]
    pub admission: Option<Box<crate::scene_packet::Admission>>,
    #[serde(skip)]
    pub temporal: Option<crate::temporal::TemporalInput>,
    #[serde(default)]
    pub shadows: crate::shadows::ShadowFrame,
    #[serde(skip)]
    pub environment: Option<crate::lighting::Environment>,
    #[serde(default)]
    pub color_pipeline: Option<ColorPipeline>,
    pub version: u32,
    #[serde(default)]
    pub settings: RenderSettings,
    pub view_projection: [f32; 16],
    pub background: [f64; 3],
    #[serde(default = "one")]
    pub background_alpha: f32,
    pub light_direction: [f32; 3],
    pub ambient: f32,
    #[serde(default)]
    pub lights: Vec<crate::lighting::PunctualLight>,
    #[serde(default)]
    pub hemispheres: Vec<crate::lighting::HemisphereLight>,
    #[serde(default)]
    pub areas: Vec<crate::lighting::RectAreaLight>,
    pub geometries: Vec<Geometry>,
    pub meshes: Vec<Mesh>,
    #[serde(default)]
    pub textures: Vec<SceneTexture>,
    #[serde(skip)]
    pub binary: Option<crate::scene_packet::ViewState>,
    #[serde(skip)]
    pub geometry_patches: Vec<GeometryPatch>,
    #[serde(skip)]
    pub instances: Vec<crate::instances::Instances>,
    #[serde(skip)]
    pub poses: Vec<crate::deformation::Pose>,
    #[serde(skip)]
    pub instance_patches: Vec<crate::instances::InstancePatch>,
    #[serde(skip)]
    pub graph: Option<crate::resources::registry::ResourceKey>,
}

#[derive(Clone, Copy, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ColorPipeline {
    #[serde(default = "single_sample")]
    pub sample_count: u32,
    pub tone_mapping: u32,
    pub exposure: f32,
}
fn single_sample() -> u32 {
    1
}
impl ColorPipeline {
    pub fn validate(&self) -> Result<(), String> {
        if ![1, 4].contains(&self.sample_count)
            || self.tone_mapping > 6
            || !self.exposure.is_finite()
            || !(0.0..=1e6).contains(&self.exposure)
        {
            return Err("invalid HDR color pipeline".into());
        }
        Ok(())
    }
}
impl Frame {
    pub fn sample_count(&self) -> u32 {
        self.color_pipeline
            .map_or(self.settings.sample_count, |pipeline| pipeline.sample_count)
    }
    pub fn validate(&self, cached: &HashSet<u32>) -> Result<(), String> {
        self.settings.validate()?;
        self.shadows
            .validate_with_areas(&self.lights, &self.areas)?;
        if let Some(temporal) = &self.temporal {
            temporal.validate(self.meshes.len())?;
            if self.binary.is_none() || self.color_pipeline.is_none() || self.sample_count() != 1 {
                return Err("Temporal AA needs a binary scene view and single-sample HDR".into());
            }
        }
        if self.areas.len() > crate::lighting::MAX_AREAS {
            return Err("scene exceeds area light limit".into());
        }
        for light in &self.areas {
            light.validate()?;
        }
        if let Some(pipeline) = self.color_pipeline {
            pipeline.validate()?;
        }
        if self.hemispheres.len() > crate::lighting::MAX_HEMISPHERES {
            return Err("scene exceeds hemisphere light limit".into());
        }
        for light in &self.hemispheres {
            light.validate()?;
        }
        if self.lights.len() > crate::lighting::MAX_LIGHTS {
            return Err("scene exceeds punctual light limit".into());
        }
        for light in &self.lights {
            light.validate()?;
        }
        if self.version != 1 {
            return Err("unsupported scene protocol version".into());
        }
        if self.meshes.len() > MAX_MESHES || self.geometries.len() > MAX_MESHES {
            return Err("scene exceeds the mesh limit".into());
        }
        if self.view_projection.iter().any(|v| !v.is_finite())
            || !self.background_alpha.is_finite()
            || !(0.0..=1.0).contains(&self.background_alpha)
            || self
                .background
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
            || self.light_direction.iter().any(|v| !v.is_finite())
            || glam::Vec3::from_array(self.light_direction).length_squared() < 1e-12
            || !self.ambient.is_finite()
            || !(0.0..=1.0).contains(&self.ambient)
        {
            return Err("invalid camera, background or light".into());
        }
        let mut added = HashSet::new();
        let mut vertices = 0;
        let mut indices = 0;
        for geometry in &self.geometries {
            geometry.validate()?;
            if cached.contains(&geometry.id) || !added.insert(geometry.id) {
                return Err("geometry identifiers are immutable and must be unique".into());
            }
            vertices += geometry.positions.len();
            indices += geometry.indices.len();
        }
        if vertices > MAX_VERTICES || indices > MAX_INDICES {
            return Err("geometry upload exceeds the per-frame budget".into());
        }

        for mesh in &self.meshes {
            mesh.validate_material()?;
            if !cached.contains(&mesh.geometry) && !added.contains(&mesh.geometry) {
                return Err("mesh refers to a missing geometry".into());
            }
            let model = glam::Mat4::from_cols_array(&mesh.model);
            if mesh.model.iter().any(|v| !v.is_finite())
                || !model.determinant().is_finite()
                || model.determinant().abs() < 1e-20
                || mesh
                    .color
                    .iter()
                    .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
            {
                return Err("mesh requires a finite invertible transform and an RGB color".into());
            }
        }
        if added
            .iter()
            .any(|id| !self.meshes.iter().any(|mesh| mesh.geometry == *id))
        {
            return Err("uploaded geometry must be referenced by a mesh".into());
        }
        Ok(())
    }
}

pub fn pixel_len(width: u32, height: u32) -> Result<usize, String> {
    if width == 0 || height == 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        return Err(format!(
            "frame size must be between 1 and {MAX_DIMENSION} pixels per axis"
        ));
    }
    Ok(width as usize * height as usize * 4)
}
