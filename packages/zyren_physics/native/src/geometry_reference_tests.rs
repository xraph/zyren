use super::capsule_poly_distance_tests as geometry;

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

#[test]
fn triangulated_convex_distance_matches_piecewise_segment_box_distance() {
    let mut seed = 0xad19_6ba5_4e32_b617u64;
    let mut sample = || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        (seed >> 11) as f64 / (1u64 << 53) as f64 * 2.0 - 1.0
    };
    for index in 0..20_000 {
        let scale = [0.001, 0.25, 1.0, 4.0, 1000.0][index % 5];
        let half = [
            0.1 + sample().abs() * 20.0,
            0.1 + sample().abs() * 2.0,
            0.1 + sample().abs() * 20.0,
        ]
        .map(|n| n * scale);
        let [x, y, z] = half;
        let vertices = [
            [-x, -y, -z],
            [x, -y, -z],
            [x, -y, z],
            [-x, -y, z],
            [-x, y, -z],
            [x, y, -z],
            [x, y, z],
            [-x, y, z],
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
            triangles.push([vertices[f[0]], vertices[f[1]], vertices[f[2]]]);
            triangles.push([vertices[f[0]], vertices[f[2]], vertices[f[3]]]);
        }
        let planes = [
            ([1., 0., 0.], x),
            ([-1., 0., 0.], x),
            ([0., 1., 0.], y),
            ([0., -1., 0.], y),
            ([0., 0., 1.], z),
            ([0., 0., -1.], z),
        ];
        let a = core::array::from_fn(|i| sample() * half[i] * 3.0);
        let b = if index % 17 == 0 {
            a
        } else {
            core::array::from_fn(|i| sample() * half[i] * 3.0)
        };
        let box_result = closest_segment_box(a, b, half);
        let convex_result = geometry::closest_segment_convex(a, b, &triangles, &planes);
        assert!(
            (box_result.2 - convex_result.2).abs() <= 1e-10 * scale,
            "case{index} a={a:?} b={b:?} half={half:?}: box={box_result:?} convex={convex_result:?}"
        );
    }
}
