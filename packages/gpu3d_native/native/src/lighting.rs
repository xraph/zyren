use serde::Deserialize;

pub const MAX_LIGHTS: usize = 16;
pub const MAX_HEMISPHERES: usize = 4;

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StandardMaterial {
    pub metallic: f32,
    pub roughness: f32,
    pub emissive: [f32; 3],
    #[serde(default = "one")]
    pub normal_scale: f32,
    #[serde(default = "one")]
    pub occlusion_strength: f32,
    #[serde(default)]
    pub normal_map: Option<crate::scene::ColorMap>,
    #[serde(default)]
    pub metallic_roughness_map: Option<crate::scene::ColorMap>,
    #[serde(default)]
    pub occlusion_map: Option<crate::scene::ColorMap>,
    #[serde(default)]
    pub emissive_map: Option<crate::scene::ColorMap>,
}
fn one() -> f32 {
    1.
}
impl StandardMaterial {
    pub fn maps(&self) -> [Option<&crate::scene::ColorMap>; 4] {
        [
            self.normal_map.as_ref(),
            self.metallic_roughness_map.as_ref(),
            self.occlusion_map.as_ref(),
            self.emissive_map.as_ref(),
        ]
    }
    pub fn validate(&self) -> Result<(), String> {
        for map in self.maps().into_iter().flatten() {
            map.validate()?;
        }
        if !self.normal_scale.is_finite() || self.normal_scale.abs() > 1e6 {
            return Err("invalid normal scale".into());
        }
        if [self.metallic, self.roughness, self.occlusion_strength]
            .iter()
            .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
            || self
                .emissive
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1e12).contains(v))
        {
            return Err("invalid standard material parameters".into());
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PunctualLight {
    pub kind: u32,
    pub color: [f32; 3],
    pub intensity: f32,
    pub position: [f32; 3],
    pub direction: [f32; 3],
    pub range: f32,
    pub inner_cos: f32,
    pub outer_cos: f32,
}
impl PunctualLight {
    pub fn validate(&self) -> Result<(), String> {
        let norm = glam::Vec3::from_array(self.direction).length_squared();
        if self.kind > 2
            || self
                .color
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
            || !self.intensity.is_finite()
            || !(0.0..=1e12).contains(&self.intensity)
            || self.position.iter().any(|v| !v.is_finite())
            || !norm.is_finite()
            || (norm - 1.).abs() > 1e-4
            || !self.range.is_finite()
            || !(0.0..=1e12).contains(&self.range)
            || !self.inner_cos.is_finite()
            || !self.outer_cos.is_finite()
            || (self.kind == 2
                && (!(0.0..=1.0).contains(&self.outer_cos)
                    || self.inner_cos < self.outer_cos
                    || self.inner_cos > 1.))
        {
            return Err("invalid punctual light".into());
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HemisphereLight {
    pub sky_color: [f32; 3],
    pub ground_color: [f32; 3],
    pub direction: [f32; 3],
    pub intensity: f32,
}
impl HemisphereLight {
    pub fn validate(&self) -> Result<(), String> {
        let norm = glam::Vec3::from_array(self.direction).length_squared();
        if !norm.is_finite()
            || (norm - 1.).abs() > 1e-4
            || !self.intensity.is_finite()
            || !(0.0..=1e12).contains(&self.intensity)
            || self
                .sky_color
                .iter()
                .chain(&self.ground_color)
                .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
        {
            return Err("invalid hemisphere light".into());
        }
        Ok(())
    }
}
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct HemisphereUniform {
    sky_intensity: [f32; 4],
    ground: [f32; 4],
    direction: [f32; 4],
}
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct LightUniform {
    position_kind: [f32; 4],
    direction_range: [f32; 4],
    color_intensity: [f32; 4],
    cone: [f32; 4],
}
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct LightingUniform {
    count: [u32; 4],
    lights: [LightUniform; MAX_LIGHTS],
    hemispheres: [HemisphereUniform; MAX_HEMISPHERES],
}
impl LightingUniform {
    pub fn capture(lights: &[PunctualLight], hemispheres: &[HemisphereLight]) -> Self {
        use bytemuck::Zeroable;
        let mut result = Self::zeroed();
        result.count[0] = lights.len() as u32;
        result.count[1] = hemispheres.len() as u32;
        for (output, light) in result.hemispheres.iter_mut().zip(hemispheres) {
            output.sky_intensity = [
                light.sky_color[0],
                light.sky_color[1],
                light.sky_color[2],
                light.intensity,
            ];
            output.ground = [
                light.ground_color[0],
                light.ground_color[1],
                light.ground_color[2],
                0.,
            ];
            output.direction = [
                light.direction[0],
                light.direction[1],
                light.direction[2],
                0.,
            ];
        }
        for (output, light) in result.lights.iter_mut().zip(lights) {
            output.position_kind = [
                light.position[0],
                light.position[1],
                light.position[2],
                light.kind as f32,
            ];
            output.direction_range = [
                light.direction[0],
                light.direction[1],
                light.direction[2],
                light.range,
            ];
            output.color_intensity = [
                light.color[0],
                light.color[1],
                light.color[2],
                light.intensity,
            ];
            output.cone = [light.inner_cos, light.outer_cos, 0., 0.];
        }
        result
    }
}

#[derive(Clone, PartialEq)]
pub struct Environment {
    pub textures: [crate::resources::registry::ResourceKey; 3],
    pub intensity: f32,
    pub rotation: [f32; 4],
}
impl Environment {
    pub fn validate(&self) -> Result<(), String> {
        let norm = glam::Vec4::from_array(self.rotation).length_squared();
        if !self.intensity.is_finite()
            || !(0.0..=1e6).contains(&self.intensity)
            || !norm.is_finite()
            || (norm - 1.).abs() > 1e-4
        {
            return Err("Invalid environment intensity or rotation".into());
        }
        Ok(())
    }
}
