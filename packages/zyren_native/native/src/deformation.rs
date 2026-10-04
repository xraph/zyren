use crate::scene::Geometry;
use glam::{Mat4, Vec3};
use serde::Deserialize;

pub const MAX_JOINTS: usize = 256;
pub const MAX_MORPHS: usize = 64;

#[derive(Clone, PartialEq, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct MorphTarget {
    #[serde(default)]
    pub positions: Vec<[f32; 3]>,
    #[serde(default)]
    pub normals: Vec<[f32; 3]>,
    #[serde(default)]
    pub tangents: Vec<[f32; 3]>,
}

#[derive(Clone, PartialEq)]
pub struct Pose {
    pub id: u32,
    pub geometry: u32,
    pub weights: Vec<f32>,
    pub matrices: Vec<[f32; 16]>,
}
impl Pose {
    pub fn byte_length(&self) -> usize {
        272 + self.matrices.len() * 64
    }
    pub fn validate(&self, geometry: &Geometry) -> Result<(), String> {
        self.validate_with_max_joint(geometry, geometry.joints.iter().flatten().copied().max())
    }
    pub(crate) fn validate_with_max_joint(
        &self,
        geometry: &Geometry,
        max_joint: Option<u32>,
    ) -> Result<(), String> {
        if (self.weights.is_empty() && self.matrices.is_empty())
            || self.id == 0
            || self.geometry != geometry.id
            || self.weights.len() != geometry.morphs.len()
            || self.weights.len() > MAX_MORPHS
            || self.matrices.len() > MAX_JOINTS
            || self.weights.iter().any(|v| !v.is_finite() || v.abs() > 1e6)
            || (!self.matrices.is_empty()
                && (geometry.joints.is_empty()
                    || max_joint.is_some_and(|j| j as usize >= self.matrices.len())))
        {
            return Err("invalid mesh deformation descriptor".into());
        }
        for values in &self.matrices {
            let matrix = Mat4::from_cols_array(values);
            if !matrix.is_finite()
                || values[3] != 0.
                || values[7] != 0.
                || values[11] != 0.
                || values[15] != 1.
                || !matrix.inverse().is_finite()
            {
                return Err("joint matrices must be finite invertible affine transforms".into());
            }
        }
        Ok(())
    }
    pub fn gpu_values(&self, geometry: &Geometry) -> Vec<u32> {
        let mut out = vec![
            geometry.positions.len() as u32,
            self.weights.len() as u32,
            self.matrices.len() as u32,
            u32::from(!geometry.joints.is_empty()),
        ];
        out.extend(self.weights.iter().map(|v| v.to_bits()));
        out.resize(68, 0);
        out.extend(self.matrices.iter().flatten().map(|v| v.to_bits()));
        out
    }
    pub(crate) fn center(&self, bounds: &SourceBounds) -> Vec3 {
        let (mut min, mut max) = bounds.base;
        for ((a, b), weight) in bounds.morphs.iter().zip(&self.weights) {
            min += (if *weight >= 0. { *a } else { *b }) * *weight;
            max += (if *weight >= 0. { *b } else { *a }) * *weight;
        }
        if self.matrices.is_empty() {
            return min * 0.5 + max * 0.5;
        }
        let mut low = Vec3::splat(f32::INFINITY);
        let mut high = Vec3::splat(f32::NEG_INFINITY);
        for matrix in &self.matrices {
            let matrix = Mat4::from_cols_array(matrix);
            for x in [min.x, max.x] {
                for y in [min.y, max.y] {
                    for z in [min.z, max.z] {
                        let p = matrix.transform_point3(Vec3::new(x, y, z));
                        low = low.min(p);
                        high = high.max(p);
                    }
                }
            }
        }
        low * 0.5 + high * 0.5
    }
}
#[derive(Clone)]
pub(crate) struct SourceBounds {
    base: (Vec3, Vec3),
    morphs: Vec<(Vec3, Vec3)>,
    pub max_joint: Option<u32>,
}
impl SourceBounds {
    pub fn new(geometry: &Geometry) -> Self {
        fn bounds(values: &[[f32; 3]]) -> (Vec3, Vec3) {
            if values.is_empty() {
                return (Vec3::ZERO, Vec3::ZERO);
            }
            values.iter().fold(
                (Vec3::splat(f32::INFINITY), Vec3::splat(f32::NEG_INFINITY)),
                |(min, max), p| {
                    let p = Vec3::from_array(*p);
                    (min.min(p), max.max(p))
                },
            )
        }
        Self {
            base: bounds(&geometry.positions),
            morphs: geometry
                .morphs
                .iter()
                .map(|m| bounds(&m.positions))
                .collect(),
            max_joint: geometry.joints.iter().flatten().copied().max(),
        }
    }
}

impl Geometry {
    pub fn deformation_bytes(&self) -> usize {
        self.positions.len() * (if self.joints.is_empty() { 0 } else { 32 })
            + self.morphs.len() * self.positions.len() * 36
    }
    pub fn deformation_values(&self) -> Vec<u32> {
        let mut out = Vec::with_capacity(self.deformation_bytes() / 4);
        for (joints, weights) in self.joints.iter().zip(&self.weights) {
            out.extend(joints);
            out.extend(weights.iter().map(|w| w.to_bits()));
        }
        for target in &self.morphs {
            for i in 0..self.positions.len() {
                for stream in [&target.positions, &target.normals, &target.tangents] {
                    out.extend(stream.get(i).copied().unwrap_or([0.; 3]).map(f32::to_bits));
                }
            }
        }
        out
    }
    pub fn validate_deformation(&self) -> Result<(), String> {
        if self.morphs.len() > MAX_MORPHS
            || self.joints.len() != self.weights.len()
            || (!self.joints.is_empty() && self.joints.len() != self.positions.len())
            || (self.deformation_bytes() > 0 && self.topology != 0)
            || self.deformation_bytes() > 64 * 1024 * 1024
        {
            return Err("invalid deformation geometry or byte budget".into());
        }
        for weights in &self.weights {
            let sum: f32 = weights.iter().sum();
            if weights.iter().any(|v| !v.is_finite() || *v < 0.) || !sum.is_finite() || sum <= 0. {
                return Err("skin weights must be nonnegative with a positive finite sum".into());
            }
        }
        for target in &self.morphs {
            if target.positions.is_empty()
                && target.normals.is_empty()
                && target.tangents.is_empty()
            {
                return Err("empty morph target".into());
            }
            if !target.tangents.is_empty() && self.tangents.is_empty() {
                return Err("morph tangents require base tangents".into());
            }
            for stream in [&target.positions, &target.normals, &target.tangents] {
                if !stream.is_empty()
                    && (stream.len() != self.positions.len()
                        || stream.iter().flatten().any(|v| !v.is_finite()))
                {
                    return Err("morph attributes must match geometry and be finite".into());
                }
            }
        }
        Ok(())
    }
}
