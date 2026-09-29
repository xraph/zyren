use serde::Deserialize;

pub const MAX_LIGHTS: usize = 16;
pub const MAX_HEMISPHERES: usize = 4;
pub const MAX_AREAS: usize = 4;

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StandardMaterial {
    #[serde(default)]
    pub physical: Option<[f32; 16]>,
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
        if let Some(p) = self.physical
            && (p.iter().any(|v| !v.is_finite())
                || !(1.0..=10.0).contains(&p[0])
                || p[1..12].iter().any(|v| !(0.0..=1.0).contains(v))
                || p[12].abs() > 1e6
                || p[13..] != [1., 0., 0.])
        {
            return Err("invalid physical material parameters".into());
        }
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
#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RectAreaLight {
    pub position: [f32; 3],
    pub half_width: [f32; 3],
    pub half_height: [f32; 3],
    pub color: [f32; 3],
    pub intensity: f32,
}
impl RectAreaLight {
    pub fn validate(&self) -> Result<(), String> {
        let normal =
            glam::Vec3::from_array(self.half_width).cross(glam::Vec3::from_array(self.half_height));
        if self
            .position
            .iter()
            .chain(&self.half_width)
            .chain(&self.half_height)
            .any(|v| !v.is_finite())
            || !normal.length_squared().is_finite()
            || normal.length_squared() < 1e-20
            || !self.intensity.is_finite()
            || !(0.0..=1e12).contains(&self.intensity)
            || self
                .color
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
        {
            return Err("invalid rectangular area light".into());
        }
        Ok(())
    }
}
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(crate) struct AreaUniform {
    position: [f32; 4],
    half_width: [f32; 4],
    half_height: [f32; 4],
    color_intensity: [f32; 4],
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
    areas: [AreaUniform; MAX_AREAS],
}
impl LightingUniform {
    pub fn capture(
        lights: &[PunctualLight],
        hemispheres: &[HemisphereLight],
        areas: &[RectAreaLight],
    ) -> Self {
        use bytemuck::Zeroable;
        let mut result = Self::zeroed();
        result.count[0] = lights.len() as u32;
        result.count[1] = hemispheres.len() as u32;
        result.count[2] = areas.len() as u32;
        for (output, light) in result.areas.iter_mut().zip(areas) {
            output.position = [light.position[0], light.position[1], light.position[2], 0.];
            output.half_width = [
                light.half_width[0],
                light.half_width[1],
                light.half_width[2],
                0.,
            ];
            output.half_height = [
                light.half_height[0],
                light.half_height[1],
                light.half_height[2],
                0.,
            ];
            output.color_intensity = [
                light.color[0],
                light.color[1],
                light.color[2],
                light.intensity,
            ];
        }
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

#[cfg(test)]
mod physical_tests {
    use super::StandardMaterial;

    #[test]
    fn physical_parameters_validate_across_the_json_boundary() {
        let mut material: StandardMaterial = serde_json::from_value(serde_json::json!({
            "metallic": 0, "roughness": 1, "emissive": [0,0,0],
            "physical": [1.5,1,0,0,1,1,1,1,0,0,0,0,0,1,0,0]
        }))
        .unwrap();
        material.validate().unwrap();
        let good = material.physical.unwrap();
        for index in 0..16 {
            for invalid in [f32::NAN, f32::INFINITY] {
                let mut value = good;
                value[index] = invalid;
                material.physical = Some(value);
                assert!(material.validate().is_err(), "nonfinite slot {index}");
            }
        }
        for (index, invalid) in [
            (0, 0.9),
            (0, 11.),
            (1, -0.1),
            (11, 1.1),
            (13, 0.),
            (14, 1.),
            (15, 1.),
        ] {
            let mut value = good;
            value[index] = invalid;
            material.physical = Some(value);
            assert!(material.validate().is_err(), "invalid slot {index}");
        }
    }
}

#[cfg(test)]
mod area_tests {
    use super::RectAreaLight;
    #[test]
    fn rejects_degenerate_nonfinite_and_unbounded_area_lights() {
        let good = RectAreaLight {
            position: [0., 0., 2.],
            half_width: [1., 0., 0.],
            half_height: [0., 1., 0.],
            color: [1.; 3],
            intensity: 1.,
        };
        good.validate().unwrap();
        for light in [
            RectAreaLight {
                half_height: [2., 0., 0.],
                ..good.clone()
            },
            RectAreaLight {
                half_width: [f32::INFINITY, 0., 0.],
                ..good.clone()
            },
            RectAreaLight {
                color: [-1., 0., 0.],
                ..good.clone()
            },
            RectAreaLight {
                intensity: f32::NAN,
                ..good.clone()
            },
            RectAreaLight {
                position: [0., f32::INFINITY, 0.],
                ..good.clone()
            },
        ] {
            assert!(light.validate().is_err());
        }
    }
}
