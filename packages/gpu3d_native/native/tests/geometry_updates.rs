use gpu3d_runtime::scene::{AttributeRange, Geometry, GeometryPatch};
fn triangle() -> Geometry {
    Geometry {
        id: 7,
        positions: vec![[0., 0., 0.], [1., 0., 0.], [0., 1., 0.]],
        normals: vec![[0., 0., 1.]; 3],
        indices: vec![0, 1, 2],
        uv0: vec![[0., 0.]; 3],
        uv1: vec![],
    }
}
#[test]
fn ranges_validate_before_replacing_immutable_geometry() {
    let base = triangle();
    let mut patch = GeometryPatch {
        id: 8,
        base: 7,
        ranges: vec![AttributeRange {
            semantic: 0,
            first: 1,
            values: vec![2., 3., 4.],
        }],
    };
    let next = patch.apply(&base).unwrap();
    assert_eq!(base.positions[1], [1., 0., 0.]);
    assert_eq!(next.positions[1], [2., 3., 4.]);
    assert_eq!(next.id, 8);
    assert_eq!(next.indices, base.indices);
    patch.ranges[0].first = u32::MAX;
    assert!(patch.apply(&base).is_err());
    patch.ranges[0].first = 0;
    patch.ranges[0].semantic = 1;
    patch.ranges[0].values = vec![0.; 3];
    assert!(patch.apply(&base).is_err());
    patch.ranges[0].semantic = 3;
    patch.ranges[0].values = vec![0.; 2];
    assert!(patch.apply(&base).is_err());
    patch.ranges[0].semantic = 0;
    patch.ranges[0].values = vec![f32::INFINITY, 0., 0.];
    assert!(patch.apply(&base).is_err());
    patch.id = 7;
    assert!(patch.apply(&base).is_err());
}
#[test]
fn overlapping_semantics_merge_gpu_rows_but_duplicate_attribute_ranges_fail() {
    let mut patch = GeometryPatch {
        id: 8,
        base: 7,
        ranges: vec![
            AttributeRange {
                semantic: 0,
                first: 0,
                values: vec![2., 0., 0., 3., 0., 0.],
            },
            AttributeRange {
                semantic: 1,
                first: 0,
                values: vec![0., 1., 0.],
            },
            AttributeRange {
                semantic: 2,
                first: 2,
                values: vec![0.5, 0.25],
            },
        ],
    };
    assert!(patch.apply(&triangle()).is_ok());
    assert_eq!(patch.gpu_ranges(), vec![(0, 0, 2), (1, 2, 3)]);
    patch.ranges.insert(1, patch.ranges[0].clone());
    assert!(patch.apply(&triangle()).is_err());
}
