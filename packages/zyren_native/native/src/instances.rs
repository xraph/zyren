use glam::Mat4;

pub const MAX_INSTANCES: usize = 100_000;
pub const INSTANCE_STRIDE: usize = 128;

#[derive(Clone, PartialEq)]
pub struct Instances {
    pub id: u32,
    pub transforms: Vec<[f32; 16]>,
    pub colors: Vec<[f32; 3]>,
}
#[derive(Clone, PartialEq)]
pub struct InstanceRange {
    pub first: usize,
    pub transforms: Vec<[f32; 16]>,
    pub colors: Vec<[f32; 3]>,
}
#[derive(Clone, PartialEq)]
pub struct InstancePatch {
    pub id: u32,
    pub base: u32,
    pub ranges: Vec<InstanceRange>,
}
impl Instances {
    pub fn validate(&self) -> Result<(), String> {
        if self.id == 0 || self.transforms.is_empty() || self.transforms.len() > MAX_INSTANCES {
            return Err("invalid instance capacity or identifier".into());
        }
        if self.colors.len() != self.transforms.len()
            || self
                .colors
                .iter()
                .flatten()
                .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
        {
            return Err("instance colors require one finite linear RGB value per transform".into());
        }
        for values in &self.transforms {
            let matrix = Mat4::from_cols_array(values);
            if !matrix.is_finite()
                || values[3] != 0.
                || values[7] != 0.
                || values[11] != 0.
                || values[15] != 1.
                || !matrix.determinant().is_finite()
                || matrix.determinant().abs() < 1e-20
                || !matrix.inverse().is_finite()
            {
                return Err("instances require finite invertible affine transforms".into());
            }
        }
        Ok(())
    }
    pub fn byte_length(&self) -> usize {
        self.transforms.len() * INSTANCE_STRIDE
    }
    pub fn gpu_values(&self, range: std::ops::Range<usize>) -> Vec<f32> {
        let mut values = Vec::with_capacity(range.len() * 32);
        for index in range {
            let transform = &self.transforms[index];
            let matrix = Mat4::from_cols_array(transform);
            let normal = matrix.inverse().transpose();
            values.extend_from_slice(transform);
            values.extend_from_slice(&[
                normal.x_axis.x,
                normal.x_axis.y,
                normal.x_axis.z,
                matrix.determinant().signum(),
            ]);
            values.extend_from_slice(&[normal.y_axis.x, normal.y_axis.y, normal.y_axis.z, 0.]);
            values.extend_from_slice(&[normal.z_axis.x, normal.z_axis.y, normal.z_axis.z, 0.]);
            values.extend_from_slice(&self.colors[index]);
            values.push(1.);
        }
        values
    }
}
impl InstancePatch {
    pub fn apply(&self, base: &Instances) -> Result<Instances, String> {
        base.validate()?;
        if self.id == 0
            || self.id == self.base
            || base.id != self.base
            || self.ranges.is_empty()
            || self.ranges.len() > 64
        {
            return Err("invalid instance patch".into());
        }
        let mut next = base.clone();
        next.id = self.id;
        let mut previous_end = 0;
        for range in &self.ranges {
            let end = range
                .first
                .checked_add(range.transforms.len())
                .filter(|end| *end <= next.transforms.len())
                .ok_or("instance range exceeds capacity")?;
            if range.transforms.is_empty()
                || range.first < previous_end
                || range.colors.len() != range.transforms.len()
            {
                return Err("instance ranges must be nonempty, ordered and disjoint".into());
            }
            next.transforms[range.first..end].copy_from_slice(&range.transforms);
            next.colors[range.first..end].copy_from_slice(&range.colors);
            previous_end = end;
        }
        next.validate()?;
        Ok(next)
    }
}
