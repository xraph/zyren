use serde::Deserialize;

pub const MAX_LIGHTS: usize = 16;

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StandardMaterial {
    pub metallic: f32,
    pub roughness: f32,
    pub emissive: [f32; 3],
}
impl StandardMaterial {
    pub fn validate(&self) -> Result<(), String> {
        if [self.metallic, self.roughness]
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
}
impl LightingUniform {
    pub fn capture(lights: &[PunctualLight]) -> Self {
        use bytemuck::Zeroable;
        let mut result = Self::zeroed();
        result.count[0] = lights.len() as u32;
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
