use serde::Deserialize;

pub const ATLAS_SIZE: u32 = 2048;
pub const MAX_SHADOW_LIGHTS: usize = crate::lighting::MAX_LIGHTS + crate::lighting::MAX_AREAS;
pub const MAX_VIEWS: usize = 128;
pub const ATLAS_BYTES: u64 = ATLAS_SIZE as u64 * ATLAS_SIZE as u64 * 4;
pub const MAX_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ShadowView {
    pub light_index: u32,
    pub kind: u32,
    pub resolution: u32,
    pub revision: u32,
    pub view_projection: [f32; 16],
    pub near: f32,
    pub far: f32,
    pub blend: f32,
    pub strength: f32,
    pub bias: f32,
    pub normal_bias: f32,
    pub slope_bias: f32,
    pub filter_radius: f32,
}

#[derive(Clone, Default, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ShadowFrame {
    pub views: Vec<ShadowView>,
    pub forward: [f32; 3],
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct AtlasRect {
    pub x: u32,
    pub y: u32,
    pub size: u32,
}

impl ShadowFrame {
    pub fn validate(&self, lights: &[crate::lighting::PunctualLight]) -> Result<(), String> {
        self.validate_with_areas(lights, &[])
    }
    pub fn validate_with_areas(
        &self,
        lights: &[crate::lighting::PunctualLight],
        areas: &[crate::lighting::RectAreaLight],
    ) -> Result<(), String> {
        if self.views.is_empty() {
            return Ok(());
        }
        if self.views.len() > MAX_VIEWS
            || (glam::Vec3::from_array(self.forward).length_squared() - 1.).abs() > 1e-4
            || self.forward.iter().any(|v| !v.is_finite())
        {
            return Err("Invalid shadow view count or camera direction".into());
        }
        let kind = |index: usize| -> Result<u32, String> {
            if index >= crate::lighting::MAX_LIGHTS {
                areas
                    .get(index - crate::lighting::MAX_LIGHTS)
                    .map(|_| 3)
                    .ok_or_else(|| "Invalid area shadow light index".into())
            } else {
                lights
                    .get(index)
                    .map(|l| l.kind)
                    .ok_or_else(|| "Invalid shadow light index".into())
            }
        };
        let mut counts = [0; MAX_SHADOW_LIGHTS];
        let mut previous = 0;
        for view in &self.views {
            if view.light_index as usize >= MAX_SHADOW_LIGHTS || view.kind > 3 {
                return Err("Invalid shadow light index or kind".into());
            }
            let matrix = glam::Mat4::from_cols_array(&view.view_projection);
            if view.kind != kind(view.light_index as usize)?
                || view.light_index < previous
                || view.view_projection.iter().any(|v| !v.is_finite())
                || !matrix.determinant().is_finite()
                || matrix.determinant() == 0.
                || !view.near.is_finite()
                || !view.far.is_finite()
                || view.near <= 0.
                || view.far <= view.near
                || view.far > 1e6
                || !(128..=1024).contains(&view.resolution)
                || !view.resolution.is_power_of_two()
            {
                return Err("Invalid shadow projection or resolution".into());
            }
            for (value, maximum) in [
                (view.blend, 0.5),
                (view.strength, 1.),
                (view.bias, 0.1),
                (view.normal_bias, 1e4),
                (view.slope_bias, 0.1),
                (view.filter_radius, 4.),
            ] {
                if !value.is_finite() || !(0.0..=maximum).contains(&value) {
                    return Err("Invalid shadow bias, filter or blend".into());
                }
            }
            previous = view.light_index;
            counts[view.light_index as usize] += 1;
        }
        for (index, count) in counts.into_iter().enumerate() {
            if count == 0 {
                continue;
            }
            let valid = match kind(index)? {
                0 => (1..=4).contains(&count),
                1 => count == 6,
                3 => count == 24,
                _ => count == 1,
            };
            if !valid {
                return Err("Incomplete or excessive shadow face set".into());
            }
            let views: Vec<_> = self
                .views
                .iter()
                .filter(|v| v.light_index as usize == index)
                .collect();
            let first = views[0];
            if views.iter().any(|v| {
                v.resolution != first.resolution
                    || v.revision != first.revision
                    || v.bias != first.bias
                    || v.normal_bias != first.normal_bias
                    || v.slope_bias != first.slope_bias
                    || v.filter_radius != first.filter_radius
                    || v.strength != first.strength
                    || v.blend != first.blend
            }) {
                return Err("Shadow faces must share their light settings".into());
            }
            for pair in views.windows(2) {
                if first.kind == 0 && (pair[0].far != pair[1].near || pair[0].near >= pair[1].near)
                {
                    return Err("Directional shadow intervals must be contiguous".into());
                }
                if (first.kind == 1 || first.kind == 3)
                    && (pair[0].near != pair[1].near || pair[0].far != pair[1].far)
                {
                    return Err("Point shadow faces must share clipping".into());
                }
            }
        }
        self.pack().map(|_| ())
    }

    pub fn pack(&self) -> Result<Vec<AtlasRect>, String> {
        let mut indices: Vec<_> = (0..self.views.len()).collect();
        indices.sort_by_key(|&i| std::cmp::Reverse(self.views[i].resolution));
        let mut occupied = [[false; 16]; 16];
        let mut result = vec![
            AtlasRect {
                x: 0,
                y: 0,
                size: 0
            };
            self.views.len()
        ];
        for i in indices {
            let size = self.views[i].resolution;
            if !(128..=1024).contains(&size) || !size.is_power_of_two() {
                return Err("Invalid shadow map extent".into());
            }
            let blocks = size as usize / 128;
            let mut found = None;
            'scan: for y in (0..16).step_by(blocks) {
                for x in (0..16).step_by(blocks) {
                    if (y..y + blocks).all(|row| (x..x + blocks).all(|col| !occupied[row][col])) {
                        found = Some((x, y));
                        break 'scan;
                    }
                }
            }
            let (x, y) = found.ok_or("Shadow maps exceed the 2048-square atlas")?;
            for row in occupied.iter_mut().skip(y).take(blocks) {
                row[x..x + blocks].fill(true);
            }
            result[i] = AtlasRect {
                x: x as u32 * 128,
                y: y as u32 * 128,
                size,
            };
        }
        Ok(result)
    }
}
