use crate::scene::{Frame, Geometry};
use glam::{Mat4, Vec3};

pub(super) fn geometry_bounds(geometry: &Geometry) -> [Vec3; 2] {
    let mut min = Vec3::splat(f32::INFINITY);
    let mut max = Vec3::splat(f32::NEG_INFINITY);
    for position in &geometry.positions {
        let p = Vec3::from_array(*position);
        min = min.min(p);
        max = max.max(p);
    }
    [min, max]
}

pub(super) fn sorted(frame: &Frame, center: impl Fn(u32) -> Vec3) -> Vec<usize> {
    let vp = Mat4::from_cols_array(&frame.view_projection);
    let depths: Vec<_> = frame
        .meshes
        .iter()
        .map(|mesh| {
            let clip = vp * Mat4::from_cols_array(&mesh.model) * center(mesh.geometry).extend(1.);
            if clip.w.abs() > 1e-20 {
                clip.z / clip.w
            } else {
                clip.z
            }
        })
        .collect();
    let mut order: Vec<_> = (0..frame.meshes.len()).collect();
    order.sort_by(|&a, &b| {
        let left = &frame.meshes[a];
        let right = &frame.meshes[b];
        let blended = left.alpha_mode == 2;
        blended
            .cmp(&(right.alpha_mode == 2))
            .then(left.render_order.cmp(&right.render_order))
            .then_with(|| {
                if blended {
                    depths[b].total_cmp(&depths[a])
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .then(a.cmp(&b))
    });
    order
}
