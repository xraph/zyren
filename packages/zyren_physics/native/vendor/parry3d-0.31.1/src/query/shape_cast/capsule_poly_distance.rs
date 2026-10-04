//! Double-precision closest points for a translated capsule's center segment.
//! The caller supplies finite geometry and complete outward convex face planes.

// Zyren modification (2026-10-04): bounded capsule casts. See ZYREN_PATCH.md.

pub type Point = [f64; 3];
pub type Closest = (Point, Point, f64);

fn add(a: Point, b: Point) -> Point {
    core::array::from_fn(|i| a[i] + b[i])
}
fn sub(a: Point, b: Point) -> Point {
    core::array::from_fn(|i| a[i] - b[i])
}
fn scale(a: Point, k: f64) -> Point {
    a.map(|x| x * k)
}
fn dot(a: Point, b: Point) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}
fn cross(a: Point, b: Point) -> Point {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}
fn squared(a: Point) -> f64 {
    dot(a, a)
}
fn pair(a: Point, b: Point) -> Closest {
    (a, b, squared(sub(a, b)).sqrt())
}
fn choose(best: &mut Closest, candidate: Closest) {
    // Strict comparison preserves the first feature when distances tie.
    if candidate.2 < best.2 {
        *best = candidate;
    }
}
fn closest_point_segment(p: Point, a: Point, b: Point) -> Point {
    let ab = sub(b, a);
    let denom = squared(ab);
    if denom == 0.0 {
        a
    } else {
        add(a, scale(ab, (dot(sub(p, a), ab) / denom).clamp(0.0, 1.0)))
    }
}
fn inside_triangle(p: Point, triangle: [Point; 3], normal: Point) -> bool {
    (0..3).all(|i| {
        dot(
            cross(sub(triangle[(i + 1) % 3], triangle[i]), sub(p, triangle[i])),
            normal,
        ) >= 0.0
    })
}
fn closest_point_triangle(p: Point, triangle: [Point; 3]) -> Point {
    let n = cross(sub(triangle[1], triangle[0]), sub(triangle[2], triangle[0]));
    let n2 = squared(n);
    if n2 > 0.0 {
        let projected = sub(p, scale(n, dot(sub(p, triangle[0]), n) / n2));
        if inside_triangle(projected, triangle, n) {
            return projected;
        }
    }
    let mut best = pair(p, triangle[0]);
    for i in 0..3 {
        choose(
            &mut best,
            pair(
                p,
                closest_point_segment(p, triangle[i], triangle[(i + 1) % 3]),
            ),
        );
    }
    best.1
}
fn closest_segments(a: Point, b: Point, c: Point, d: Point) -> Closest {
    let mut best = pair(a, closest_point_segment(a, c, d));
    choose(&mut best, pair(b, closest_point_segment(b, c, d)));
    choose(&mut best, pair(closest_point_segment(c, a, b), c));
    choose(&mut best, pair(closest_point_segment(d, a, b), d));
    let u = sub(b, a);
    let v = sub(d, c);
    let w = sub(a, c);
    let denom = squared(cross(u, v));
    if denom > 0.0 {
        let uu = squared(u);
        let vv = squared(v);
        let uv = dot(u, v);
        let uw = dot(u, w);
        let vw = dot(v, w);
        let s = (uv * vw - vv * uw) / denom;
        let t = (uu * vw - uv * uw) / denom;
        if (0.0..=1.0).contains(&s) && (0.0..=1.0).contains(&t) {
            choose(&mut best, pair(add(a, scale(u, s)), add(c, scale(v, t))));
        }
    }
    best
}

/// Return (segment witness, triangle witness, unsigned distance).
/// A zero-length center segment is valid. Degenerate triangles reduce to edges.
pub fn closest_segment_triangle(a: Point, b: Point, triangle: [Point; 3]) -> Closest {
    let origin = triangle[0];
    let shifted = triangle.map(|p| sub(p, origin));
    let (segment, face, distance) =
        closest_segment_triangle_local(sub(a, origin), sub(b, origin), shifted);
    (add(segment, origin), add(face, origin), distance)
}

fn closest_segment_triangle_local(a: Point, b: Point, triangle: [Point; 3]) -> Closest {
    let normal = cross(sub(triangle[1], triangle[0]), sub(triangle[2], triangle[0]));
    let da = dot(sub(a, triangle[0]), normal);
    let db = dot(sub(b, triangle[0]), normal);
    let denominator = da - db;
    if squared(normal) > 0.0 && denominator != 0.0 {
        let t = da / denominator;
        if (0.0..=1.0).contains(&t) {
            let crossing = add(a, scale(sub(b, a), t));
            if inside_triangle(crossing, triangle, normal) {
                return (crossing, crossing, 0.0);
            }
        }
    }
    let mut best = pair(a, closest_point_triangle(a, triangle));
    choose(&mut best, pair(b, closest_point_triangle(b, triangle)));
    for i in 0..3 {
        choose(
            &mut best,
            closest_segments(a, b, triangle[i], triangle[(i + 1) % 3]),
        );
    }
    best
}

/// Return closest points against a closed convex solid.
/// Planes describe n.dot(point) <= offset, with outward unit normals. The caller
/// must supply every face, triangulated in `triangles`, and at least four planes.
pub fn closest_segment_convex(
    a: Point,
    b: Point,
    triangles: &[[Point; 3]],
    planes: &[(Point, f64)],
) -> Closest {
    assert!(!triangles.is_empty() && planes.len() >= 4);
    for endpoint in [a, b] {
        if planes
            .iter()
            .all(|&(normal, offset)| dot(normal, endpoint) <= offset)
        {
            return (endpoint, endpoint, 0.0);
        }
    }
    let mut best = closest_segment_triangle(a, b, triangles[0]);
    for &triangle in &triangles[1..] {
        choose(&mut best, closest_segment_triangle(a, b, triangle));
        if best.2 == 0.0 {
            break;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;
    const TRIANGLE: [Point; 3] = [[-10.0, 0.0, -10.0], [10.0, 0.0, -10.0], [0.0, 0.0, 10.0]];
    fn near(a: f64, b: f64) {
        assert!((a - b).abs() <= 1e-10 * b.abs().max(1.0), "{a} != {b}");
    }
    fn point_near(a: Point, b: Point) {
        for i in 0..3 {
            near(a[i], b[i]);
        }
    }
    fn cube() -> (Vec<[Point; 3]>, Vec<(Point, f64)>) {
        let p = [
            [-1., -1., -1.],
            [1., -1., -1.],
            [1., -1., 1.],
            [-1., -1., 1.],
            [-1., 1., -1.],
            [1., 1., -1.],
            [1., 1., 1.],
            [-1., 1., 1.],
        ];
        let faces = [
            [0, 1, 2, 3],
            [4, 7, 6, 5],
            [0, 4, 5, 1],
            [1, 5, 6, 2],
            [2, 6, 7, 3],
            [3, 7, 4, 0],
        ];
        let mut triangles = Vec::new();
        for f in faces {
            triangles.push([p[f[0]], p[f[1]], p[f[2]]]);
            triangles.push([p[f[0]], p[f[2]], p[f[3]]]);
        }
        let planes = vec![
            ([1., 0., 0.], 1.),
            ([-1., 0., 0.], 1.),
            ([0., 1., 0.], 1.),
            ([0., -1., 0.], 1.),
            ([0., 0., 1.], 1.),
            ([0., 0., -1.], 1.),
        ];
        (triangles, planes)
    }
    #[test]
    fn triangle_face_edge_vertex_and_crossing_witnesses() {
        let result = closest_segment_triangle([0., 0.3, 0.], [0., 1.3, 0.], TRIANGLE);
        point_near(result.0, [0., 0.3, 0.]);
        point_near(result.1, [0., 0., 0.]);
        near(result.2, 0.3);
        let edge = closest_segment_triangle([0., 2., -12.], [0., 3., -12.], TRIANGLE);
        point_near(edge.1, [0., 0., -10.]);
        near(edge.2, 8f64.sqrt());
        let vertex = closest_segment_triangle([0., 2., 12.], [0., 3., 12.], TRIANGLE);
        point_near(vertex.1, [0., 0., 10.]);
        near(vertex.2, 8f64.sqrt());
        let crossing = closest_segment_triangle([0., -1., 0.], [0., 1., 0.], TRIANGLE);
        point_near(crossing.0, [0., 0., 0.]);
        near(crossing.2, 0.);
    }
    #[test]
    fn parallel_segment_crosses_face_projection_with_both_endpoints_outside() {
        let result = closest_segment_triangle([-20., 0.3, 0.], [20., 0.3, 0.], TRIANGLE);
        near(result.2, 0.3);
        near(result.0[1], 0.3);
        near(result.1[1], 0.);
        let coplanar = closest_segment_triangle([-20., 0., 0.], [20., 0., 0.], TRIANGLE);
        near(coplanar.2, 0.);
    }
    #[test]
    fn degenerate_segments_triangles_and_winding_are_stable() {
        let p = [0., 0.3, 0.];
        near(closest_segment_triangle(p, p, TRIANGLE).2, 0.3);
        near(
            closest_segment_triangle(p, p, [TRIANGLE[2], TRIANGLE[1], TRIANGLE[0]]).2,
            0.3,
        );
        near(closest_segment_triangle(p, p, [[0.; 3]; 3]).2, 0.3);
        near(
            closest_segment_triangle(p, p, [[-1., 0., 0.], [1., 0., 0.], [0., 0., 0.]]).2,
            0.3,
        );
        near(
            closest_segments([0., 0., 0.], [1., 0., 0.], [0., 0.3, 0.], [1., 0.3, 0.]).2,
            0.3,
        );
        near(
            closest_segments([0., 0., 0.], [1., 0., 0.], [0.5, -1., 0.3], [0.5, 1., 0.3]).2,
            0.3,
        );
    }
    #[test]
    fn distance_is_invariant_under_rigid_transform_and_scales_with_geometry() {
        for size in [1e-4, 0.25, 1., 4., 1e4] {
            let transform = |p: Point| [3. + p[1] * size, -7. + p[2] * size, 11. + p[0] * size];
            let result = closest_segment_triangle(
                transform([0., 0.3, 0.]),
                transform([0., 1.3, 0.]),
                TRIANGLE.map(transform),
            );
            near(result.2, 0.3 * size);
            point_near(result.1, transform([0., 0., 0.]));
        }
    }
    #[test]
    fn convex_face_edge_vertex_inside_and_through_solid() {
        let (triangles, planes) = cube();
        for (a, b, distance) in [
            ([0., 1.3, 0.], [0., 2.3, 0.], 0.3),
            ([1.3, 1.4, 0.], [1.3, 2.4, 0.], 0.5),
            ([1.3, 1.4, 2.2], [1.3, 2.4, 2.2], 1.3),
            ([0., 0., 0.], [0., 0.5, 0.], 0.),
            ([0., -2., 0.], [0., 2., 0.], 0.),
            ([0., 1., 0.], [0., 2., 0.], 0.),
        ] {
            near(
                closest_segment_convex(a, b, &triangles, &planes).2,
                distance,
            );
        }
    }
    #[test]
    fn capsule_floor_distance_retains_sub_millimeter_clearance() {
        for x in [-0.0005013872, -0.04, 0., 0.123, 1.44] {
            for y in [0.8007928, 0.809872, 0.81, 0.8101] {
                let result = closest_segment_triangle([x, y - 0.5, x], [x, y + 0.5, x], TRIANGLE);
                near(result.2, y - 0.5);
                point_near(result.1, [x, 0., x]);
            }
        }
    }

    #[test]
    fn random_triangle_witnesses_certify_the_global_separating_distance() {
        let mut seed = 0x92c6_0527_6135_a449u64;
        let mut sample = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            (seed >> 11) as f64 / ((1u64 << 53) as f64) * 2.0 - 1.0
        };
        for index in 0..20_000 {
            let factor = [0.001, 1.0, 1000.0][index % 3];
            let translation = [sample() * 1e3, sample() * 1e3, sample() * 1e3];
            let mut point = || core::array::from_fn(|i| translation[i] + sample() * factor);
            let triangle = [point(), point(), point()];
            let a = point();
            let b = if index % 11 == 0 { a } else { point() };
            let (p, q, distance) = closest_segment_triangle(a, b, triangle);
            assert!(distance.is_finite() && distance >= 0.0);
            if distance <= 1e-10 * factor {
                continue;
            }
            let normal = scale(sub(p, q), 1.0 / distance);
            // Restoring the local witnesses to the caller's coordinates costs
            // an absolute rounding error. Normalization amplifies that error
            // when the closest points are almost coincident.
            let coordinates = a
                .into_iter()
                .chain(b)
                .chain(triangle.into_iter().flatten())
                .map(f64::abs)
                .fold(1.0, f64::max);
            let witness_error = 32.0 * f64::EPSILON * coordinates;
            let tolerance = 1e-10 * factor + witness_error * (1.0 + 4.0 * factor / distance);
            // A normal separates the complete convex sets only when each
            // witness is an extremum of its set along that same normal.
            for endpoint in [a, b] {
                assert!(
                    dot(sub(endpoint, p), normal) >= -tolerance,
                    "segment certificate at {index}: {a:?} {b:?} {triangle:?} -> {p:?} {q:?}"
                );
            }
            for vertex in triangle {
                assert!(
                    dot(sub(vertex, q), normal) <= tolerance,
                    "triangle certificate at {index}: {a:?} {b:?} {triangle:?} -> {p:?} {q:?}"
                );
            }
        }
    }
}
