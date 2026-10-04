// Zyren modification (2026-10-04): bounded capsule casts. See ZYREN_PATCH.md.
use super::capsule_poly_distance::{closest_segment_convex, closest_segment_triangle};
use crate::math::{Pose, Real, Vector};
use crate::query::{
    sat, ContactManifold, DefaultQueryDispatcher, PersistentQueryDispatcher, ShapeCastHit,
    ShapeCastOptions, ShapeCastStatus,
};
use crate::shape::{Capsule, ConvexPolyhedron, Cuboid, Shape, Triangle};
use alloc::vec::Vec;

fn closest_segment_box(a: [f64; 3], b: [f64; 3], half: [f64; 3]) -> ([f64; 3], [f64; 3], f64) {
    let d = core::array::from_fn::<_, 3, _>(|i| b[i] - a[i]);
    let mut knots = [0.0; 8];
    knots[1] = 1.0;
    let mut count = 2;
    for i in 0..3 {
        if d[i] != 0.0 {
            for bound in [-half[i], half[i]] {
                let t = (bound - a[i]) / d[i];
                if t > 0.0 && t < 1.0 {
                    knots[count] = t;
                    count += 1;
                }
            }
        }
    }
    knots[..count].sort_unstable_by(f64::total_cmp);
    let mut best = (a, [0.0; 3], f64::INFINITY);
    let mut evaluate = |t: f64| {
        let p = core::array::from_fn::<_, 3, _>(|i| a[i] + t * d[i]);
        let q = core::array::from_fn::<_, 3, _>(|i| p[i].clamp(-half[i], half[i]));
        let dist2 = (0..3).map(|i| (p[i] - q[i]).powi(2)).sum::<f64>();
        if dist2 < best.2 {
            best = (p, q, dist2);
        }
    };
    for window in knots[..count].windows(2) {
        let mid = (window[0] + window[1]) * 0.5;
        let mut numerator = 0.0;
        let mut denominator = 0.0;
        for i in 0..3 {
            let sample = a[i] + d[i] * mid;
            let bound = if sample < -half[i] {
                -half[i]
            } else if sample > half[i] {
                half[i]
            } else {
                continue;
            };
            numerator += d[i] * (a[i] - bound);
            denominator += d[i] * d[i];
        }
        evaluate(window[0]);
        evaluate(window[1]);
        if denominator > 0.0 {
            evaluate((-numerator / denominator).clamp(window[0], window[1]));
        }
    }
    best.2 = best.2.sqrt();
    best
}

fn vec64(v: Vector) -> [f64; 3] {
    [v.x as f64, v.y as f64, v.z as f64]
}
fn vec_real(v: [f64; 3]) -> Vector {
    Vector::new(v[0] as Real, v[1] as Real, v[2] as Real)
}

/// Translational capsule cast using exact segment-to-box distance and bounded conservative advancement.
pub fn cast_shapes_cuboid_capsule(
    pos12: &Pose,
    vel12: Vector,
    cuboid: &Cuboid,
    capsule: &Capsule,
    options: ShapeCastOptions,
) -> Option<ShapeCastHit> {
    let half = vec64(cuboid.half_extents);
    cast_capsule(pos12, vel12, cuboid, capsule, options, |a, b| {
        closest_segment_box(a, b, half)
    })
}

/// Translational capsule cast against a triangle using exact segment distance.
pub fn cast_shapes_triangle_capsule(
    pos12: &Pose,
    vel12: Vector,
    triangle: &Triangle,
    capsule: &Capsule,
    options: ShapeCastOptions,
) -> Option<ShapeCastHit> {
    let vertices = [vec64(triangle.a), vec64(triangle.b), vec64(triangle.c)];
    cast_capsule(pos12, vel12, triangle, capsule, options, |a, b| {
        closest_segment_triangle(a, b, vertices)
    })
}

/// Translational capsule cast against a convex polyhedron using its complete boundary.
pub fn cast_shapes_convex_capsule(
    pos12: &Pose,
    vel12: Vector,
    convex: &ConvexPolyhedron,
    capsule: &Capsule,
    options: ShapeCastOptions,
) -> Option<ShapeCastHit> {
    let mut triangles = Vec::new();
    let mut planes = Vec::new();
    let adjacency = convex.vertices_adj_to_face();
    let vertices = convex.points();
    for face in convex.faces() {
        let start = face.first_vertex_or_edge as usize;
        let ids = &adjacency[start..start + face.num_vertices_or_edges as usize];
        let anchor = vec64(vertices[ids[0] as usize]);
        let mut normal = [0.0; 3];
        let mut area_squared = 0.0;
        for j in 1..ids.len() - 1 {
            let p1 = vec64(vertices[ids[j] as usize]);
            let p2 = vec64(vertices[ids[j + 1] as usize]);
            let d1 = core::array::from_fn::<_, 3, _>(|i| p1[i] - anchor[i]);
            let d2 = core::array::from_fn::<_, 3, _>(|i| p2[i] - anchor[i]);
            let cross = [
                d1[1] * d2[2] - d1[2] * d2[1],
                d1[2] * d2[0] - d1[0] * d2[2],
                d1[0] * d2[1] - d1[1] * d2[0],
            ];
            let candidate_area = cross.iter().map(|v| v * v).sum::<f64>();
            if candidate_area > area_squared {
                normal = cross;
                area_squared = candidate_area;
            }
        }
        if area_squared == 0.0
            || !area_squared.is_finite()
            || !face.normal.is_finite()
            || face.normal.length_squared() == 0.0
        {
            return Some(failed_initial(pos12, vel12, capsule));
        }
        let length = area_squared.sqrt();
        let outward = vec64(face.normal);
        let sign = if (0..3).map(|i| normal[i] * outward[i]).sum::<f64>() >= 0.0 {
            1.0
        } else {
            -1.0
        };
        normal = normal.map(|v| v / length * sign);
        planes.push((normal, (0..3).map(|i| normal[i] * anchor[i]).sum::<f64>()));
        for j in 1..ids.len() - 1 {
            triangles.push([
                anchor,
                vec64(vertices[ids[j] as usize]),
                vec64(vertices[ids[j + 1] as usize]),
            ]);
        }
    }
    if planes.len() < 4 || triangles.is_empty() {
        return Some(failed_initial(pos12, vel12, capsule));
    }
    cast_capsule(pos12, vel12, convex, capsule, options, |a, b| {
        closest_segment_convex(a, b, &triangles, &planes)
    })
}

fn cast_capsule<F>(
    pos12: &Pose,
    vel12: Vector,
    shape1: &dyn Shape,
    capsule: &Capsule,
    options: ShapeCastOptions,
    distance_fn: F,
) -> Option<ShapeCastHit>
where
    F: Fn([f64; 3], [f64; 3]) -> ([f64; 3], [f64; 3], f64),
{
    let a0 = vec64(pos12 * capsule.segment.a);
    let b0 = vec64(pos12 * capsule.segment.b);
    let velocity = vec64(vel12);
    let radius = capsule.radius as f64;
    let target = radius + options.target_distance as f64;
    let tolerance = 1.0e-12 * target.max(1.0);
    let mut t = 0.0;
    for iteration in 0..64 {
        let a = core::array::from_fn::<_, 3, _>(|i| a0[i] + t * velocity[i]);
        let b = core::array::from_fn::<_, 3, _>(|i| b0[i] + t * velocity[i]);
        let (segment, box_point, distance) = distance_fn(a, b);
        let mut moved = *pos12;
        moved.translation += vel12 * t as Real;
        let mut geometry_failed = false;
        let (normal, witness1, witness2) = if distance > 0.0 {
            let delta = core::array::from_fn::<_, 3, _>(|i| segment[i] - box_point[i]);
            let delta_length = delta.iter().map(|v| v * v).sum::<f64>().sqrt();
            if delta_length == 0.0 || !delta_length.is_finite() {
                return Some(failed_initial(pos12, vel12, capsule));
            }
            let normal = vec_real(delta.map(|v| v / delta_length));
            let capsule_point = vec_real(core::array::from_fn::<_, 3, _>(|i| {
                segment[i] - (segment[i] - box_point[i]) / delta_length * radius
            }));
            (
                normal,
                vec_real(box_point),
                moved.inverse_transform_point(capsule_point),
            )
        } else {
            let mut manifold = ContactManifold::<(), ()>::new();
            let _ = DefaultQueryDispatcher.contact_manifold_convex_convex(
                &moved,
                shape1,
                capsule,
                None,
                None,
                options.target_distance,
                &mut manifold,
            );
            if let Some(point) = manifold
                .points
                .iter()
                .filter(|point| {
                    point.local_p1.is_finite()
                        && point.local_p2.is_finite()
                        && point.dist.is_finite()
                })
                .min_by(|a, b| a.dist.total_cmp(&b.dist))
                .filter(|_| {
                    manifold.local_n1.is_finite()
                        && (manifold.local_n1.length_squared() - 1.0).abs() < 1.0e-5
                })
            {
                (manifold.local_n1, point.local_p1, point.local_p2)
            } else {
                geometry_failed = true;
                let normal = if let Some(cuboid) = shape1.as_cuboid() {
                    let face = sat::cuboid_support_map_find_local_separating_normal_oneway(
                        cuboid,
                        &capsule.segment,
                        &moved,
                    );
                    let edge = sat::cuboid_segment_find_local_separating_edge_twoway(
                        cuboid,
                        &capsule.segment,
                        &moved,
                    );
                    if face.0 >= edge.0 {
                        face.1
                    } else {
                        edge.1
                    }
                } else {
                    (-vel12).try_normalize().unwrap_or(Vector::Y)
                };
                (
                    normal,
                    vec_real(box_point),
                    moved.inverse_transform_point(vec_real(segment) - normal * capsule.radius),
                )
            }
        };
        let gap = distance - target;
        if gap <= tolerance {
            if t == 0.0
                && !geometry_failed
                && !options.stop_at_penetration
                && normal.dot(vel12) >= 0.0
            {
                return None;
            }
            return Some(ShapeCastHit {
                time_of_impact: t as Real,
                normal1: normal,
                normal2: pos12.rotation.inverse() * -normal,
                witness1,
                witness2,
                status: if geometry_failed {
                    ShapeCastStatus::Failed
                } else if t == 0.0 && gap < 0.0 {
                    ShapeCastStatus::PenetratingOrWithinTargetDist
                } else {
                    ShapeCastStatus::Converged
                },
                subshape1: 0,
                subshape2: 0,
            });
        }
        let delta_length = (0..3)
            .map(|i| (segment[i] - box_point[i]).powi(2))
            .sum::<f64>()
            .sqrt();
        let closing = -(0..3)
            .map(|i| (segment[i] - box_point[i]) / delta_length * velocity[i])
            .sum::<f64>();
        if closing <= 0.0 {
            return None;
        }
        let next = t + gap / closing;
        if next > options.max_time_of_impact as f64 {
            return None;
        }
        if iteration == 63 || next <= t {
            return Some(ShapeCastHit {
                time_of_impact: t as Real,
                normal1: normal,
                normal2: pos12.rotation.inverse() * -normal,
                witness1,
                witness2,
                status: if iteration == 63 {
                    ShapeCastStatus::OutOfIterations
                } else {
                    ShapeCastStatus::Failed
                },
                subshape1: 0,
                subshape2: 0,
            });
        }
        t = next;
    }
    unreachable!()
}

fn failed_initial(pos12: &Pose, vel12: Vector, capsule: &Capsule) -> ShapeCastHit {
    let normal = (-vel12).try_normalize().unwrap_or(Vector::Y);
    ShapeCastHit {
        time_of_impact: 0.0,
        normal1: normal,
        normal2: pos12.rotation.inverse() * -normal,
        witness1: Vector::ZERO,
        witness2: capsule.segment.a,
        status: ShapeCastStatus::Failed,
        subshape1: 0,
        subshape2: 0,
    }
}
