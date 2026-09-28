use crate::scene::{Frame, Geometry};
use glam::{Mat4, Vec3};

pub(super) fn geometry_center(geometry: &Geometry) -> Vec3 {
    let mut min = Vec3::splat(f32::INFINITY);
    let mut max = Vec3::splat(f32::NEG_INFINITY);
    for position in &geometry.positions {
        let p = Vec3::from_array(*position);
        min = min.min(p);
        max = max.max(p);
    }
    min * 0.5 + max * 0.5
}

pub(super) struct Draw {
    pub mesh: usize,
    pub instances: std::ops::Range<u32>,
    depth: f32,
}
pub(super) fn sorted(
    frame: &Frame,
    center: impl Fn(&crate::scene::Mesh) -> Vec3,
    transform: impl Fn(u32, u32) -> Mat4,
) -> Vec<Draw> {
    let vp = Mat4::from_cols_array(&frame.view_projection);
    let mut order = Vec::new();
    for (index, mesh) in frame.meshes.iter().enumerate() {
        if mesh.alpha_mode != 2 {
            order.push(Draw {
                mesh: index,
                instances: 0..mesh.instance_count,
                depth: 0.,
            });
            continue;
        }
        let mvp = vp * Mat4::from_cols_array(&mesh.model);
        for instance in 0..mesh.instance_count {
            let local = if mesh.instances == 0 {
                Mat4::IDENTITY
            } else {
                transform(mesh.instances, instance)
            };
            let clip = mvp * local * center(mesh).extend(1.);
            let depth = if clip.w.abs() > 1e-20 {
                clip.z / clip.w
            } else {
                clip.z
            };
            order.push(Draw {
                mesh: index,
                instances: instance..instance + 1,
                depth,
            });
        }
    }
    order.sort_by(|a, b| {
        let left = &frame.meshes[a.mesh];
        let right = &frame.meshes[b.mesh];
        let blended = left.alpha_mode == 2;
        blended
            .cmp(&(right.alpha_mode == 2))
            .then(left.render_order.cmp(&right.render_order))
            .then_with(|| {
                if blended {
                    b.depth.total_cmp(&a.depth)
                } else {
                    std::cmp::Ordering::Equal
                }
            })
            .then(a.mesh.cmp(&b.mesh))
            .then(a.instances.start.cmp(&b.instances.start))
    });
    order
}
