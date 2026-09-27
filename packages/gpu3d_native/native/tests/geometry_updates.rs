use gpu3d_runtime::scene::{AttributeRange, Geometry, GeometryPatch};
fn triangle() -> Geometry {
    Geometry {
        id: 7,
        positions: vec![[0., 0., 0.], [1., 0., 0.], [0., 1., 0.]],
        normals: vec![[0., 0., 1.]; 3],
        indices: vec![0, 1, 2],
        index_format: Default::default(),
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

#[test]
fn index_width_cannot_truncate_and_keeps_cpu_admission_separate() {
    use gpu3d_runtime::scene::IndexFormat;
    let mut geometry = triangle();
    geometry.index_format = IndexFormat::Uint16;
    assert_eq!(geometry.byte_length(), 126);
    assert_eq!(geometry.cpu_byte_length(), 108);
    geometry.positions.resize(65537, [0.; 3]);
    geometry.normals.resize(65537, [0., 0., 1.]);
    geometry.uv0.resize(65537, [0.; 2]);
    geometry.indices[1] = 65536;
    assert!(geometry.validate().is_err());
    geometry.index_format = IndexFormat::Uint32;
    assert!(geometry.validate().is_ok());
}
