use crate::scene::Geometry;
use glam::Vec3;

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
