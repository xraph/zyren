use glam::{DVec3, Mat4, Vec3};
use std::collections::HashSet;

pub const MAX_BYTES: u64 = 256 * 1024 * 1024;
#[derive(Clone, PartialEq)]
pub struct TemporalInput {
    pub history_weight: f32,
    pub depth_tolerance: f32,
    pub max_bytes: u64,
    pub reset: u64,
    pub camera: u64,
    pub origin: [f64; 3],
    pub forward: [f32; 3],
    pub target_distance: f32,
    pub projection: [f32; 16],
    pub identities: Vec<[u64; 2]>,
}
impl TemporalInput {
    pub fn validate(&self, meshes: usize) -> Result<(), String> {
        let normal = Vec3::from_array(self.forward).length_squared();
        let mut unique = HashSet::new();
        if !self.history_weight.is_finite()
            || !(0.0..1.0).contains(&self.history_weight)
            || !self.depth_tolerance.is_finite()
            || !(1e-5..=0.1).contains(&self.depth_tolerance)
            || self.max_bytes == 0
            || self.max_bytes > MAX_BYTES
            || self.camera == 0
            || self.origin.iter().any(|v| !v.is_finite())
            || !normal.is_finite()
            || (normal - 1.).abs() > 1e-4
            || !self.target_distance.is_finite()
            || self.target_distance <= 0.
            || self.projection.iter().any(|v| !v.is_finite())
            || self.identities.len() != meshes
            || self
                .identities
                .iter()
                .any(|p| p[0] == 0 || p[1] == 0 || !unique.insert(p[0]))
        {
            return Err("invalid temporal reconstruction metadata".into());
        }
        Ok(())
    }
    pub fn camera_cut(&self, previous: &Self) -> bool {
        self.reset != previous.reset
            || self.camera != previous.camera
            || self.projection != previous.projection
            || self.history_weight != previous.history_weight
            || self.depth_tolerance != previous.depth_tolerance
            || Vec3::from_array(self.forward).dot(Vec3::from_array(previous.forward))
                < std::f32::consts::FRAC_1_SQRT_2
            || DVec3::from_array(self.origin).distance(DVec3::from_array(previous.origin))
                > f64::from(self.target_distance.min(previous.target_distance)) * 0.5
    }
}
fn radical_inverse(mut n: u32, base: u32) -> f32 {
    let mut value = 0.;
    let mut factor = 1.;
    while n > 0 {
        factor /= base as f32;
        value += (n % base) as f32 * factor;
        n /= base;
    }
    value
}
pub fn jitter(matrix: [f32; 16], size: [u32; 2], phase: u32) -> [f32; 16] {
    let index = phase % 8 + 1;
    let offset = Vec3::new(
        (radical_inverse(index, 2) - 0.4453125) * 2. / size[0] as f32,
        (radical_inverse(index, 3) - 0.5) * 2. / size[1] as f32,
        0.,
    );
    (Mat4::from_translation(offset) * Mat4::from_cols_array(&matrix)).to_cols_array()
}
#[cfg(test)]
mod tests {
    use super::*;
    fn input() -> TemporalInput {
        TemporalInput {
            history_weight: 0.9,
            depth_tolerance: 0.01,
            max_bytes: 128 * 1024 * 1024,
            reset: 0,
            camera: 1,
            origin: [1e12, 0., 3.],
            forward: [0., 0., -1.],
            target_distance: 3.,
            projection: Mat4::IDENTITY.to_cols_array(),
            identities: vec![[1, 1]],
        }
    }
    #[test]
    fn accepts_small_motion_but_resets_cuts_projection_and_explicit_generation() {
        let old = input();
        let mut next = old.clone();
        next.origin[0] += 0.25;
        assert!(!next.camera_cut(&old));
        next.origin[0] += 2.;
        assert!(next.camera_cut(&old));
        next = old.clone();
        next.reset += 1;
        assert!(next.camera_cut(&old));
        next = old.clone();
        next.projection[0] = 2.;
        assert!(next.camera_cut(&old));
        next = old.clone();
        next.forward = [0., 0., 1.];
        assert!(next.camera_cut(&old));
    }
    #[test]
    fn metadata_rejects_bad_identities_and_nonfinite_inputs() {
        let mut value = input();
        value.validate(1).unwrap();
        value.identities.push([1, 2]);
        assert!(value.validate(2).is_err());
        value = input();
        value.origin[0] = f64::NAN;
        assert!(value.validate(1).is_err());
        value = input();
        value.history_weight = 1.;
        assert!(value.validate(1).is_err());
    }
    #[test]
    fn jitter_cycle_is_centered_subpixel_and_does_not_change_depth() {
        let mut sum = Vec3::ZERO;
        for phase in 0..8 {
            let matrix =
                Mat4::from_cols_array(&jitter(Mat4::IDENTITY.to_cols_array(), [100, 50], phase));
            let point = matrix.transform_point3(Vec3::new(0., 0., 0.7));
            assert_eq!(point.z, 0.7);
            assert!(point.x.abs() < 0.01 && point.y.abs() < 0.02);
            sum += point - Vec3::new(0., 0., 0.7);
        }
        assert!(sum.length() < 1e-7);
    }
}
