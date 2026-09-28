use gpu3d_runtime::scene::{AttributeRange, Geometry, GeometryPatch};
fn triangle() -> Geometry {
    Geometry {
        id: 7,
        topology: 0,
        positions: vec![[0., 0., 0.], [1., 0., 0.], [0., 1., 0.]],
        normals: vec![[0., 0., 1.]; 3],
        indices: vec![0, 1, 2],
        index_format: Default::default(),
        uv0: vec![[0., 0.]; 3],
        uv1: vec![],
        tangents: vec![],
        colors: vec![],
        joints: vec![],
        weights: vec![],
        morphs: vec![],
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

#[test]
fn expanded_geometry_requires_a_full_recipe_update() {
    let mut base = triangle();
    base.topology = 3;
    base.uv0.clear();
    let patch = GeometryPatch {
        id: 8,
        base: 7,
        ranges: vec![AttributeRange {
            semantic: 0,
            first: 0,
            values: vec![1., 2., 3.],
        }],
    };
    assert!(patch.apply(&base).is_err());
    assert_eq!(base.positions[0], [0., 0., 0.]);
}

#[test]
fn tangent_ranges_keep_handedness_and_use_their_own_buffer() {
    let mut base = triangle();
    base.tangents = vec![[1., 0., 0., 1.]; 3];
    let mut patch = GeometryPatch {
        id: 8,
        base: 7,
        ranges: vec![AttributeRange {
            semantic: 4,
            first: 1,
            values: vec![1., 0., 0., -1.],
        }],
    };
    let next = patch.apply(&base).unwrap();
    assert_eq!(next.tangents[1], [1., 0., 0., -1.]);
    assert_eq!(base.tangents[1], [1., 0., 0., 1.]);
    assert_eq!(patch.gpu_ranges(), vec![(2, 1, 2)]);
    patch.ranges[0].values[3] = 0.;
    assert!(patch.apply(&base).is_err());
    patch.ranges[0].values = vec![0., 0., 0., 1.];
    assert!(patch.apply(&base).is_err());
    patch.ranges[0].values = vec![1., 0., 0., 1.];
    base.tangents.clear();
    assert!(patch.apply(&base).is_err());
}

#[test]
fn color_ranges_validate_rgba_and_keep_their_own_gpu_rows() {
    let mut base = triangle();
    base.colors = vec![[1., 0., 0., 1.]; 3];
    let mut patch = GeometryPatch {
        id: 8,
        base: 7,
        ranges: vec![AttributeRange {
            semantic: 5,
            first: 1,
            values: vec![0.25, 0.5, 0.75, 0.],
        }],
    };
    let next = patch.apply(&base).unwrap();
    assert_eq!(next.colors[1], [0.25, 0.5, 0.75, 0.]);
    assert_eq!(base.colors[1], [1., 0., 0., 1.]);
    assert_eq!(patch.gpu_ranges(), vec![(3, 1, 2)]);
    assert_eq!(base.byte_length(), 180);
    assert_eq!(base.cpu_byte_length(), 156);
    for invalid in [-0.1, 1.1, f32::NAN, f32::INFINITY] {
        patch.ranges[0].values[3] = invalid;
        assert!(patch.apply(&base).is_err());
    }
    patch.ranges[0].values[3] = 1.;
    base.colors.clear();
    assert!(patch.apply(&base).is_err());
}
