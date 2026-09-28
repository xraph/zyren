pub use crate::geometry_update::{AttributeRange, GeometryPatch};
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
            return self.primitive_count() * 120;
        }
        self.positions.len()
            * (if self.uv0.is_empty() && self.uv1.is_empty() {
                24
            } else {
                40
            })
            + self.tangents.len() * 16
            + self.indices.len() * self.index_format.bytes()
    }
    pub fn cpu_byte_length(&self) -> usize {
        (self.positions.len() + self.normals.len()) * 12
            + (self.uv0.len() + self.uv1.len()) * 8
            + self.tangents.len() * 16
            + self.indices.len() * 4
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.topology > 3
            || (self.topology != 0
                && (self.primitive_count() > 250_000
                    || !self.uv0.is_empty()
                    || !self.uv1.is_empty()
                    || !self.tangents.is_empty()))
        {
            return Err("unsupported primitive topology, attributes or expanded budget".into());
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
    #[serde(default = "full_coverage")]
    pub coverage: [f32; 2],
    #[serde(default)]
    pub instances: Vec<[f32; 16]>,
    pub geometry: u32,
    pub model: [f32; 16],
    pub color: [f32; 3],
    pub unlit: bool,
    #[serde(default)]
    pub color_map: Option<ColorMap>,
    #[serde(default)]
    pub alpha_mode: u32,
    #[serde(default)]
    pub side: u32,
    #[serde(default)]
    pub shader: Option<[u64; 4]>,
    #[serde(default)]
    pub pbr: Option<[f32; 6]>,
    #[serde(default)]
    pub pbr_maps: [Option<ColorMap>; 4],
    #[serde(default = "pbr_scales")]
    pub pbr_scales: [f32; 3],
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
    #[serde(default = "default_shadow_flags")]
    pub shadow_flags: u32,
    #[serde(default)]
    pub clipping_planes: Vec<[f32; 4]>,
    #[serde(default)]
    pub outlined: bool,
}
fn default_shadow_flags() -> u32 {
    2
}
fn pbr_scales() -> [f32; 3] {
    [1.; 3]
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

impl Default for Mesh {
    fn default() -> Self {
        Self {
            coverage: full_coverage(),
            geometry: 0,
            instances: Vec::new(),
            model: glam::Mat4::IDENTITY.to_cols_array(),
            color: [1.; 3],
            unlit: false,
            color_map: None,
            alpha_mode: 0,
            side: 0,
            shader: None,
            pbr: None,
            pbr_maps: Default::default(),
            pbr_scales: pbr_scales(),
            opacity: 1.,
            alpha_cutoff: 0.5,
            depth_test: true,
            depth_write: None,
            render_order: 0,
            primitive_kind: 0,
            primitive_size: 1.,
            size_units: 0,
            point_shape: 0,
            shadow_flags: 2,
            clipping_planes: Vec::new(),
            outlined: false,
        }
    }
}
impl Mesh {
    pub fn material_maps(&self) -> impl Iterator<Item = &ColorMap> {
        self.color_map.iter().chain(self.pbr_maps.iter().flatten())
    }
    pub fn writes_depth(&self) -> bool {
        self.depth_write.unwrap_or(self.alpha_mode != 2)
    }
    pub fn validate_material(&self) -> Result<(), String> {
        if self.clipping_planes.len() > 6
            || (!self.clipping_planes.is_empty() && self.shader.is_some())
            || self.clipping_planes.iter().any(|plane| {
                plane.iter().any(|value| !value.is_finite())
                    || (glam::Vec3::new(plane[0], plane[1], plane[2]).length_squared() - 1.).abs()
                        > 1e-4
            })
        {
            return Err(
                "Clipping requires at most six normalized planes and a built-in material".into(),
            );
        }
        if !self.instances.is_empty()
            && (self.instances.len() > MAX_INSTANCES
                || self.shader.is_some()
                || self.primitive_kind != 0)
        {
            return Err("Instances require bounded built-in triangle materials".into());
        }
        for values in &self.instances {
            let model = glam::Mat4::from_cols_array(values);
            if !model.is_finite()
                || !model.inverse().is_finite()
                || !model.determinant().is_finite()
                || model.determinant().abs() < 1e-20
                || values[3] != 0.
                || values[7] != 0.
                || values[11] != 0.
                || values[15] != 1.
            {
                return Err("Invalid affine instance transform".into());
            }
        }
        if self.shadow_flags > 3
            || (self.shadow_flags & 1 != 0 && (self.shader.is_some() || self.primitive_kind != 0))
        {
            return Err("Invalid shadow caster flags or material".into());
        }
        if (self.pbr.is_none() && self.pbr_maps.iter().any(Option::is_some))
            || self.pbr_scales.iter().any(|v| !v.is_finite())
            || self.pbr_scales[..2].iter().any(|v| v.abs() > 1e6)
            || !(0.0..=1.).contains(&self.pbr_scales[2])
        {
            return Err("Invalid PBR maps or scales".into());
        }
        for map in self.material_maps() {
            map.validate()?;
        }
        if let Some(p) = self.pbr
            && (self.shader.is_some()
                || self.primitive_kind != 0
                || p.iter().any(|v| !v.is_finite())
                || p[..2].iter().any(|v| !(0.0..=1.).contains(v))
                || !(0.0..=65504.).contains(&p[2])
                || p[3..].iter().any(|v| !(0.0..=1.).contains(v)))
        {
            return Err("Invalid PBR material".into());
        }
        if self.shader.is_some() && (self.primitive_kind != 0 || self.color_map.is_some()) {
            return Err(
                "Custom shaders require triangle geometry and explicit shader bindings".into(),
            );
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
            || (self.shader.is_some() && self.coverage != [0., 1.])
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
            .map(|m| (self.width >> m).max(1) as usize * (self.height >> m).max(1) as usize * 4)
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
            || self.format > 1
            || self.mip_generation > 2
            || (self.mip_generation != 0 && self.levels.len() != 1)
            || self.levels.is_empty()
            || self.levels.len() > (32 - self.width.max(self.height).leading_zeros()) as usize
        {
            return Err("invalid texture extent, format or mip count".into());
        }
        for (mip, level) in self.levels.iter().enumerate() {
            let size =
                (self.width >> mip).max(1) as usize * (self.height >> mip).max(1) as usize * 4;
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
#[serde(default, deny_unknown_fields)]
pub struct RenderSettings {
    pub outline: Option<OutlineSettings>,
    pub enabled: bool,
    pub sample_count: u32,
    pub depth_strategy: u32,
    pub spatial_antialiasing: u32,
    pub bloom: Option<BloomSettings>,
    pub effects: Vec<[u64; 4]>,
    pub tone_mapping: u32,
    pub exposure: f32,
    pub background_alpha: f32,
    pub history_epoch: u32,
    pub camera_origin: [f64; 3],
    pub environment: Option<EnvironmentMap>,
    pub shadows: Vec<[f32; 8]>,
    pub shadow_camera: [f32; 2],
}
impl Default for RenderSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            outline: None,
            sample_count: 1,
            depth_strategy: 0,
            spatial_antialiasing: 0,
            bloom: None,
            effects: vec![],
            tone_mapping: 0,
            exposure: 1.,
            background_alpha: 1.,
            history_epoch: 0,
            camera_origin: [0.; 3],
            environment: None,
            shadows: vec![],
            shadow_camera: [0.1, 1000.],
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
        if self.depth_strategy > 1
            || self.spatial_antialiasing > 1
            || ((self.spatial_antialiasing != 0 || self.bloom.is_some()) && !self.enabled)
            || ![1, 4].contains(&self.sample_count)
            || (self.sample_count != 1 && !self.enabled)
            || self.camera_origin.iter().any(|v| !v.is_finite())
            || self.effects.len() > 8
            || self.tone_mapping > 2
            || !self.exposure.is_finite()
            || !(0.0..=65504.).contains(&self.exposure)
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
    pub version: u32,
    #[serde(default)]
    pub settings: RenderSettings,
    #[serde(default)]
    pub lights: Vec<[f32; 20]>,
    pub view_projection: [f32; 16],
    pub background: [f64; 3],
    pub light_direction: [f32; 3],
    pub ambient: f32,
    pub geometries: Vec<Geometry>,
    pub meshes: Vec<Mesh>,
    #[serde(default)]
    pub textures: Vec<SceneTexture>,
    #[serde(skip)]
    pub binary: Option<crate::scene_packet::ViewState>,
    #[serde(skip)]
    pub geometry_patches: Vec<GeometryPatch>,
}

impl Frame {
    pub fn validate(&self, cached: &HashSet<u32>) -> Result<(), String> {
        validate_shadows(&self.settings, &self.lights)?;
        self.settings.validate()?;
        if self.lights.len() > 16
            || self.lights.iter().any(|l| {
                l.iter().any(|v| !v.is_finite())
                    || l[3] < 0.
                    || l[3] > 3.
                    || l[3].fract() != 0.
                    || l[4..7].iter().any(|v| !(0.0..=1.).contains(v))
                    || !(0.0..=1e12).contains(&l[7])
                    || !(0.0..=1e12).contains(&l[11])
                    || glam::Vec3::from_slice(&l[8..11]).length_squared() < 1e-12
                    || !(0.0..=1.).contains(&l[12])
                    || !(0.0..=1.).contains(&l[13])
                    || l[12] < l[13]
                    || l[16..19].iter().any(|v| !(0.0..=1.).contains(v))
            })
        {
            return Err("Invalid physical lights".into());
        }
        if self.version != 1 {
            return Err("unsupported scene protocol version".into());
        }
        if self.meshes.len() > MAX_MESHES || self.geometries.len() > MAX_MESHES {
            return Err("scene exceeds the mesh limit".into());
        }
        if self.view_projection.iter().any(|v| !v.is_finite())
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
        if self.meshes.iter().map(|m| m.instances.len()).sum::<usize>() > MAX_INSTANCES {
            return Err("Instance count exceeds the per-view budget".into());
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

pub(crate) fn validate_shadows(
    settings: &RenderSettings,
    light_values: &[[f32; 20]],
) -> Result<(), String> {
    let clip = settings.shadow_camera;
    if clip.iter().any(|v| !v.is_finite()) || clip[1] <= clip[0] || settings.shadows.len() > 8 {
        return Err("Invalid shadow camera or count".into());
    }
    let mut lights = HashSet::new();
    let mut maps = 0;
    for s in &settings.shadows {
        if s.iter().any(|v| !v.is_finite())
            || s[0] < 0.
            || s[0].fract() != 0.
            || s[0] as usize >= light_values.len()
            || !lights.insert(s[0] as usize)
            || ![128., 256., 512., 1024.].contains(&s[1])
            || !(1.0..=4.).contains(&s[2])
            || s[2].fract() != 0.
            || s[3] <= 0.
            || s[4] <= s[3]
            || s[4] > 1e8
            || !(0.0..=1.).contains(&s[5])
            || !(0.0..=1e6).contains(&s[6])
            || !(0.0..=1.).contains(&s[7])
        {
            return Err("Invalid shadow descriptor".into());
        }
        let light = &light_values[s[0] as usize];
        let kind = light[3];
        if (kind != 0. && kind != 2.)
            || (kind == 2. && (s[2] != 1. || light[13] <= 0. || light[13] >= 1.))
            || (kind == 0. && s[4].min(clip[1]) <= clip[0].max(0.001))
        {
            return Err("Unsupported shadow light or camera range".into());
        }
        maps += s[2] as usize;
    }
    if maps > 8 {
        return Err("Too many shadow projections".into());
    }
    Ok(())
}
