use rapier3d::parry::{
    math::{Pose, Vector},
    query::{ShapeCastOptions, ShapeCastStatus, cast_shapes},
    shape::{Capsule, Cuboid},
};

fn options(max: f32) -> ShapeCastOptions {
    ShapeCastOptions {
        max_time_of_impact: max,
        target_distance: 0.01,
        stop_at_penetration: false,
        compute_impact_geometry_on_penetration: true,
    }
}

#[test]
fn box_capsule_separation_target_and_velocity_matrix() {
    for scale in [0.25, 1.0, 4.0] {
        for width in [8.0, 20.0, 64.0] {
            let floor = Cuboid::new(Vector::new(width * scale, 0.5 * scale, width * scale));
            let capsule = Capsule::new_y(0.5 * scale, 0.3 * scale);
            let floor_pose = Pose::translation(0.0, -0.5 * scale, 0.0);
            for y in [0.8007928, 0.8076425, 0.81, 0.8101, 0.82, 1.3, 2.0] {
                for offset in [-0.06750164, 0.0005013872, 0.234567] {
                    let capsule_pose = Pose::translation(offset * scale, y * scale, offset * scale);
                    for velocity in [
                        Vector::Y,
                        -Vector::Y,
                        Vector::X,
                        Vector::new(-1.0, -0.3, -1.0),
                    ] {
                        for max in [0.001, 0.2] {
                            let mut config = options(max * scale);
                            config.target_distance *= scale;
                            let hit = cast_shapes(
                                &floor_pose,
                                Vector::ZERO,
                                &floor,
                                &capsule_pose,
                                velocity,
                                &capsule,
                                config,
                            )
                            .unwrap();
                            let gap = (y - 0.81) * scale;
                            let expected = if velocity.y < 0.0 {
                                (gap / -velocity.y).max(0.0)
                            } else {
                                f32::INFINITY
                            };
                            if expected > config.max_time_of_impact {
                                assert!(
                                    hit.is_none(),
                                    "y={y} scale={scale} v={velocity:?} max={max} hit={hit:?}"
                                );
                            } else {
                                let hit = hit.expect("approaching floor must hit within maxTOI");
                                assert!(
                                    (hit.time_of_impact - expected).abs() < 2e-6 * scale,
                                    "{hit:?} expected={expected}"
                                );
                                assert!((hit.normal1 - Vector::Y).length() < 2e-6, "{hit:?}");
                                assert!(hit.witness1.y == floor.half_extents.y, "{hit:?}");
                                assert!(
                                    (hit.witness2.y + 0.8 * scale).abs() < 2e-6 * scale,
                                    "{hit:?}"
                                );
                            }
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn box_capsule_cast_swapped_and_rotation_covariant() {
    let floor = Cuboid::new(Vector::new(20.0, 0.5, 20.0));
    let capsule = Capsule::new_y(0.5, 0.3);
    for angles in [
        Vector::ZERO,
        Vector::new(0.6, 0.3, 0.4),
        Vector::Z * core::f32::consts::FRAC_PI_2,
    ] {
        let transform = Pose::new(Vector::new(3.0, 5.0, -2.0), angles);
        let floor_pose = transform * Pose::translation(0.0, -0.5, 0.0);
        let capsule_pose = transform * Pose::translation(-0.0675, 0.95, -0.0675);
        let velocity = transform.rotation * -Vector::Y;
        let hit = cast_shapes(
            &floor_pose,
            Vector::ZERO,
            &floor,
            &capsule_pose,
            velocity,
            &capsule,
            options(0.2),
        )
        .unwrap()
        .unwrap();
        let swapped = cast_shapes(
            &capsule_pose,
            velocity,
            &capsule,
            &floor_pose,
            Vector::ZERO,
            &floor,
            options(0.2),
        )
        .unwrap()
        .unwrap();
        assert!((hit.time_of_impact - 0.14).abs() < 2e-6, "{hit:?}");
        assert!(
            (hit.time_of_impact - swapped.time_of_impact).abs() < 2e-6,
            "{hit:?} {swapped:?}"
        );
        assert!((hit.normal1 - Vector::Y).length() < 2e-6, "{hit:?}");
        assert!((hit.normal1 - swapped.normal2).length() < 2e-6);
        assert!((hit.witness1 - swapped.witness2).length() < 3e-6);
        assert!((hit.witness2 - swapped.witness1).length() < 3e-6);
    }
}

#[test]
fn box_capsule_zero_segment_and_initial_penetration() {
    let box_shape = Cuboid::new(Vector::ONE);
    for half in [0.0, 0.5] {
        let capsule = Capsule::new_y(half, 0.3);
        let touching = Pose::translation(0.0, 1.3 + half, 0.0);
        let hit = cast_shapes(
            &Pose::IDENTITY,
            Vector::ZERO,
            &box_shape,
            &touching,
            -Vector::Y,
            &capsule,
            options(0.2),
        )
        .unwrap()
        .unwrap();
        assert_eq!(hit.time_of_impact, 0.0);
        assert!((hit.normal1 - Vector::Y).length() < 2e-6);
        let overlap = Pose::translation(0.0, 0.0, 0.0);
        let mut config = options(0.2);
        config.stop_at_penetration = true;
        let hit = cast_shapes(
            &Pose::IDENTITY,
            Vector::ZERO,
            &box_shape,
            &overlap,
            -Vector::Y,
            &capsule,
            config,
        )
        .unwrap()
        .unwrap();
        assert_eq!(hit.time_of_impact, 0.0);
        assert_eq!(hit.status, ShapeCastStatus::PenetratingOrWithinTargetDist);
        assert!(hit.normal1.is_finite());
        assert!((hit.normal1.length() - 1.0).abs() < 1e-6);
        assert!(hit.witness1.is_finite() && hit.witness2.is_finite());
    }
}

#[test]
fn box_capsule_edge_tangent_separated_and_corner_hit() {
    let box_shape = Cuboid::new(Vector::ONE);
    let capsule = Capsule::new_y(0.0, 0.3);
    let start = Pose::translation(1.3, 1.3, 0.0);
    assert!(
        cast_shapes(
            &Pose::IDENTITY,
            Vector::ZERO,
            &box_shape,
            &start,
            Vector::X,
            &capsule,
            options(10.0)
        )
        .unwrap()
        .is_none()
    );
    assert!(
        cast_shapes(
            &Pose::IDENTITY,
            Vector::ZERO,
            &box_shape,
            &start,
            Vector::Z,
            &capsule,
            options(0.5)
        )
        .unwrap()
        .is_none()
    );
    let velocity = Vector::new(-1.0, -1.0, 0.0).normalize();
    let hit = cast_shapes(
        &Pose::IDENTITY,
        Vector::ZERO,
        &box_shape,
        &start,
        velocity,
        &capsule,
        options(0.5),
    )
    .unwrap()
    .unwrap();
    let expected = 0.3 * 2.0f32.sqrt() - 0.31;
    assert!((hit.time_of_impact - expected).abs() < 2e-6, "{hit:?}");
    assert!((hit.normal1 + velocity).length() < 2e-6);
    assert!((hit.witness1 - Vector::new(1.0, 1.0, 0.0)).length() < 2e-6);
    assert!(
        cast_shapes(
            &Pose::IDENTITY,
            Vector::ZERO,
            &box_shape,
            &start,
            velocity,
            &capsule,
            options(expected / 2.0)
        )
        .unwrap()
        .is_none()
    );
}

#[test]
fn triangle_and_convex_casts_preserve_normals_limits_and_pair_symmetry() {
    use rapier3d::parry::shape::{ConvexPolyhedron, Shape, Triangle};
    let triangle = Triangle::new(
        Vector::new(-20.0, 0.0, -20.0),
        Vector::new(20.0, 0.0, -20.0),
        Vector::new(0.0, 0.0, 20.0),
    );
    let vertices = vec![
        Vector::new(-20.0, -1.0, -20.0),
        Vector::new(20.0, -1.0, -20.0),
        Vector::new(-20.0, -1.0, 20.0),
        Vector::new(20.0, -1.0, 20.0),
        Vector::new(-20.0, 0.0, -20.0),
        Vector::new(20.0, 0.0, -20.0),
        Vector::new(-20.0, 0.0, 20.0),
        Vector::new(20.0, 0.0, 20.0),
    ];
    let convex = ConvexPolyhedron::from_convex_hull(&vertices).unwrap();
    let capsule = Capsule::new_y(0.5, 0.3);
    for shape in [&triangle as &dyn Shape, &convex as &dyn Shape] {
        for orientation in [
            Vector::ZERO,
            Vector::new(0.3, 0.6, 0.4),
            Vector::Z * core::f32::consts::FRAC_PI_2,
        ] {
            let floor_pose = Pose::new(Vector::new(2.0, 3.0, 4.0), orientation);
            for y in [0.8076425, 0.8101, 0.95, 1.3] {
                let capsule_pose = floor_pose * Pose::translation(-0.06750164, y, -0.06750164);
                for relative_vel in [-Vector::Y, Vector::Y, Vector::X] {
                    let velocity = floor_pose.rotation * relative_vel;
                    for max in [0.001, 0.2] {
                        let hit = cast_shapes(
                            &floor_pose,
                            Vector::ZERO,
                            shape,
                            &capsule_pose,
                            velocity,
                            &capsule,
                            options(max),
                        )
                        .unwrap();
                        let swapped = cast_shapes(
                            &capsule_pose,
                            velocity,
                            &capsule,
                            &floor_pose,
                            Vector::ZERO,
                            shape,
                            options(max),
                        )
                        .unwrap();
                        // Classify the actual admitted f32 velocity. A rotated nominal
                        // tangent can acquire a sub-ULP inward component in inverse rotation.
                        let admitted_velocity = floor_pose.rotation.inverse() * velocity;
                        let expected = if admitted_velocity.y < 0.0 {
                            ((y - 0.81) / -admitted_velocity.y).max(0.0)
                        } else {
                            f32::INFINITY
                        };
                        if expected > max {
                            assert!(hit.is_none() && swapped.is_none(), "{hit:?} {swapped:?}");
                        } else {
                            let hit = hit.unwrap();
                            let swapped = swapped.unwrap();
                            assert!((hit.time_of_impact - expected).abs() < 2e-6, "{hit:?}");
                            assert!((hit.time_of_impact - swapped.time_of_impact).abs() < 2e-6);
                            assert!((hit.normal1 - Vector::Y).length() < 2e-6, "{hit:?}");
                            assert!((hit.normal1 - swapped.normal2).length() < 2e-6);
                            assert!((hit.witness1 - swapped.witness2).length() < 3e-6);
                            assert!((hit.witness2 - swapped.witness1).length() < 3e-6);
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn convex_face_with_collinear_boundary_vertices_has_finite_cast() {
    use rapier3d::parry::shape::ConvexPolyhedron;
    let points = vec![
        Vector::new(-1.0, -1.0, -1.0),
        Vector::new(1.0, -1.0, -1.0),
        Vector::new(1.0, -1.0, 1.0),
        Vector::new(-1.0, -1.0, 1.0),
        Vector::new(-1.0, 1.0, -1.0),
        Vector::new(1.0, 1.0, -1.0),
        Vector::new(1.0, 1.0, 1.0),
        Vector::new(-1.0, 1.0, 1.0),
        Vector::new(0.0, -1.0, -1.0),
    ];
    let triangles = vec![
        [0, 8, 2],
        [8, 1, 2],
        [0, 2, 3],
        [4, 7, 6],
        [4, 6, 5],
        [0, 4, 5],
        [0, 5, 8],
        [8, 5, 1],
        [1, 5, 6],
        [1, 6, 2],
        [2, 6, 7],
        [2, 7, 3],
        [3, 7, 4],
        [3, 4, 0],
    ];
    let shape = ConvexPolyhedron::from_convex_mesh(points, &triangles).unwrap();
    let mut retained_collinear = false;
    for face in shape.faces() {
        let ids = &shape.vertices_adj_to_face()[face.first_vertex_or_edge as usize
            ..(face.first_vertex_or_edge + face.num_vertices_or_edges) as usize];
        for i in 0..ids.len() {
            let p = shape.points()[ids[i] as usize];
            let q = shape.points()[ids[(i + 1) % ids.len()] as usize];
            let r = shape.points()[ids[(i + 2) % ids.len()] as usize];
            if (q - p).cross(r - p).length_squared() == 0.0 {
                retained_collinear = true;
            }
        }
    }
    assert!(
        retained_collinear,
        "fixture must retain a collinear polygon boundary"
    );
    let capsule = Capsule::new_y(0.5, 0.3);
    let hit = cast_shapes(
        &Pose::IDENTITY,
        Vector::ZERO,
        &shape,
        &Pose::translation(0.0, -1.95, 0.0),
        Vector::Y,
        &capsule,
        options(0.2),
    )
    .unwrap()
    .unwrap();
    assert!((hit.time_of_impact - 0.14).abs() < 2e-6, "{hit:?}");
    assert!((hit.normal1 + Vector::Y).length() < 2e-6, "{hit:?}");
    assert!(hit.witness1.is_finite() && hit.witness2.is_finite());
}

#[test]
fn initial_target_shell_movement_reports_immediate_hit() {
    use rapier3d::parry::math::{Pose, Vector};
    use rapier3d::parry::query::{ShapeCastOptions, cast_shapes};
    use rapier3d::parry::shape::{Capsule, Cuboid};
    let floor = Cuboid::new(Vector::new(20.0, 0.5, 20.0));
    let capsule = Capsule::new_y(0.5, 0.3);
    let direction = Vector::new(-0.01, -0.003924, -0.01);
    let pos = Pose::translation(
        -0.06750164180994034_f64 as f32,
        0.8007928133010864_f64 as f32,
        -0.06750164180994034_f64 as f32,
    );
    let result = cast_shapes(
        &Pose::translation(0.0, -0.5, 0.0),
        Vector::ZERO,
        &floor,
        &pos,
        direction.normalize(),
        &capsule,
        ShapeCastOptions {
            max_time_of_impact: direction.length(),
            target_distance: 0.01,
            stop_at_penetration: false,
            compute_impact_geometry_on_penetration: true,
        },
    )
    .unwrap();

    let hit = result.expect("cast toward overlapping target-distance shell must hit");
    assert_eq!(hit.time_of_impact, 0.0);
    assert!((hit.normal1 - Vector::Y).length() < 2.0e-6);
    assert_eq!(hit.status, ShapeCastStatus::PenetratingOrWithinTargetDist);
}

#[test]
fn initial_target_shell_snap_has_upward_normal_and_zero_time() {
    use rapier3d::parry::math::{Pose, Vector};
    use rapier3d::parry::query::{ShapeCastOptions, cast_shapes};
    use rapier3d::parry::shape::{Capsule, Cuboid};
    let floor = Cuboid::new(Vector::new(20.0, 0.5, 20.0));
    let capsule = Capsule::new_y(0.5, 0.3);
    let pos = Pose::translation(-0.0005013872, 0.8076425, -0.0005013872);
    let result = cast_shapes(
        &Pose::translation(0.0, -0.5, 0.0),
        Vector::ZERO,
        &floor,
        &pos,
        -Vector::Y,
        &capsule,
        ShapeCastOptions {
            max_time_of_impact: 0.2,
            target_distance: 0.01,
            stop_at_penetration: false,
            compute_impact_geometry_on_penetration: true,
        },
    )
    .unwrap()
    .unwrap();

    assert_eq!(result.time_of_impact, 0.0, "already within target shell");
    assert!((result.normal1 - Vector::Y).length() < 2.0e-6);
    assert_eq!(
        result.status,
        ShapeCastStatus::PenetratingOrWithinTargetDist
    );
}
