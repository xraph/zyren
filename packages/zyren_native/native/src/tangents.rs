//! CPU-only MikkTSpace generation. The C adapter owns bounded scratch storage.
use std::sync::atomic::{AtomicU64, Ordering};

#[repr(C)]
pub struct TangentLimits {
    pub version: u32,
    pub max_working_bytes: u64,
    pub max_iterations: u64,
}
impl Default for TangentLimits {
    fn default() -> Self {
        Self {
            version: 1,
            max_working_bytes: 128 * 1024 * 1024,
            max_iterations: 100_000_000,
        }
    }
}
static USED: AtomicU64 = AtomicU64::new(0);
struct Reservation(u64);
impl Drop for Reservation {
    fn drop(&mut self) {
        USED.fetch_sub(self.0, Ordering::AcqRel);
    }
}
unsafe extern "C" {
    fn fg_mikk_bounded(
        positions: *const f32,
        normals: *const f32,
        uvs: *const f32,
        indices: *const u32,
        corners: u32,
        output: *mut f32,
        scratch_bytes: usize,
        iterations: u64,
    ) -> i32;
}

/// Generates one XYZW tangent for each indexed triangle corner. Status codes:
/// 0 success, 1 invalid data/limits, 2 limit exceeded, 3 busy, 4 internal failure.
/// # Safety
/// Input pointers must address vertex_count * (3, 3, 2) floats and corner_count
/// indices. Limits must be readable. Output must address output_length floats,
/// disjoint from every input, and is unspecified on failure. Ownership stays
/// with the caller. No renderer or GPU device is required.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_generate_tangents(
    positions: *const f32,
    normals: *const f32,
    uvs: *const f32,
    vertex_count: u32,
    indices: *const u32,
    corner_count: u32,
    limits: *const TangentLimits,
    output: *mut f32,
    output_length: usize,
) -> u32 {
    if positions.is_null()
        || normals.is_null()
        || uvs.is_null()
        || indices.is_null()
        || limits.is_null()
        || output.is_null()
        || vertex_count == 0
        || vertex_count > 1_000_000
        || corner_count == 0
        || corner_count > 3_000_000
        || !corner_count.is_multiple_of(3)
        || output_length != corner_count as usize * 4
    {
        return 1;
    }
    let limits = unsafe { &*limits };
    if limits.version != 1
        || !(1..=128 * 1024 * 1024).contains(&limits.max_working_bytes)
        || !(1..=100_000_000).contains(&limits.max_iterations)
    {
        return 1;
    }
    let positions_slice =
        unsafe { std::slice::from_raw_parts(positions, vertex_count as usize * 3) };
    let normals_slice = unsafe { std::slice::from_raw_parts(normals, vertex_count as usize * 3) };
    let uvs_slice = unsafe { std::slice::from_raw_parts(uvs, vertex_count as usize * 2) };
    let index_slice = unsafe { std::slice::from_raw_parts(indices, corner_count as usize) };
    // Keep the reference's float hash arithmetic within its numeric range.
    if positions_slice
        .iter()
        .chain(uvs_slice)
        .any(|x| !x.is_finite() || x.abs() > 1e15)
        || normals_slice.iter().any(|x| !x.is_finite())
        || normals_slice
            .chunks_exact(3)
            .any(|n| n.iter().map(|x| f64::from(*x).powi(2)).sum::<f64>() < 1e-12)
        || index_slice.iter().any(|i| *i >= vertex_count)
    {
        return 1;
    }
    if USED
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |used| {
            used.checked_add(limits.max_working_bytes)
                .filter(|total| *total <= 256 * 1024 * 1024)
        })
        .is_err()
    {
        return 3;
    }
    let _reservation = Reservation(limits.max_working_bytes);
    let status = unsafe {
        fg_mikk_bounded(
            positions,
            normals,
            uvs,
            indices,
            corner_count,
            output,
            limits.max_working_bytes as usize,
            limits.max_iterations,
        )
    };
    if status != 0 {
        return status as u32;
    }
    let tangents = unsafe { std::slice::from_raw_parts(output, output_length) };
    if tangents.chunks_exact(4).any(|t| {
        let length = t[..3].iter().map(|v| f64::from(*v).powi(2)).sum::<f64>();
        !length.is_finite() || (length - 1.0).abs() > 1e-4 || t[3].abs() != 1.0
    }) {
        return 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    fn run(mut limits: TangentLimits, indices: &[u32], positions: &[f32]) -> (u32, Vec<f32>) {
        limits.max_working_bytes = limits.max_working_bytes.min(8 * 1024 * 1024);
        let normals = [0., 0., 1.].repeat(4);
        let uvs = [0., 0., 1., 0., 0., 1., 1., 0.];
        let mut output = vec![0.; indices.len() * 4];
        let code = unsafe {
            fg2_generate_tangents(
                positions.as_ptr(),
                normals.as_ptr(),
                uvs.as_ptr(),
                4,
                indices.as_ptr(),
                indices.len() as u32,
                &limits,
                output.as_mut_ptr(),
                output.len(),
            )
        };
        (code, output)
    }
    const POSITIONS: [f32; 12] = [0., 0., 0., 1., 0., 0., 0., 1., 0., -1., 0., 0.];
    #[test]
    fn mirrored_corners_match_reference_basis() {
        let (status, output) = run(TangentLimits::default(), &[0, 1, 2, 0, 2, 3], &POSITIONS);
        assert_eq!(status, 0);
        assert_eq!(&output[..12], [1., 0., 0., 1.].repeat(3));
        assert_eq!(&output[12..], [-1., 0., 0., -1.].repeat(3));
    }
    #[test]
    fn failed_limits_release_all_scratch_and_admission() {
        for _ in 0..8 {
            assert_eq!(
                run(
                    TangentLimits {
                        max_working_bytes: 32,
                        ..Default::default()
                    },
                    &[0, 1, 2],
                    &POSITIONS
                )
                .0,
                2
            );
            assert_eq!(
                run(
                    TangentLimits {
                        max_iterations: 1,
                        ..Default::default()
                    },
                    &[0, 1, 2],
                    &POSITIONS
                )
                .0,
                2
            );
        }
        assert_eq!(run(TangentLimits::default(), &[0, 1, 2], &POSITIONS).0, 0);
    }
    #[test]
    fn high_valence_fan_returns_a_limit_instead_of_overflowing_the_stack() {
        let count = 400_u32;
        let mut positions = vec![0_f32; 3];
        let mut uvs = vec![0_f32; 2];
        for i in 0..count {
            let angle = i as f32 / count as f32 * std::f32::consts::TAU;
            positions.extend_from_slice(&[angle.cos(), angle.sin(), 0.]);
            uvs.extend_from_slice(&[angle.cos(), angle.sin()]);
        }
        let normals = [0., 0., 1.].repeat((count + 1) as usize);
        let indices = (0..count)
            .flat_map(|i| [0, i + 1, (i + 1) % count + 1])
            .collect::<Vec<_>>();
        let mut output = vec![0.; indices.len() * 4];
        let limits = TangentLimits {
            max_working_bytes: 8 * 1024 * 1024,
            ..Default::default()
        };
        let status = unsafe {
            fg2_generate_tangents(
                positions.as_ptr(),
                normals.as_ptr(),
                uvs.as_ptr(),
                count + 1,
                indices.as_ptr(),
                indices.len() as u32,
                &limits,
                output.as_mut_ptr(),
                output.len(),
            )
        };
        assert_eq!(status, 2);
        assert_eq!(run(limits, &[0, 1, 2], &POSITIONS).0, 0);
    }
    #[test]
    fn invalid_indices_coordinates_and_zero_extent() {
        assert_eq!(run(TangentLimits::default(), &[0, 1, 4], &POSITIONS).0, 1);
        let mut invalid = POSITIONS;
        invalid[0] = f32::NAN;
        assert_eq!(run(TangentLimits::default(), &[0, 1, 2], &invalid).0, 1);
        assert_eq!(run(TangentLimits::default(), &[0, 1, 2], &[0.; 12]).0, 0);
    }
}
