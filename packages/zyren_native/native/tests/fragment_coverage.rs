use zyren_runtime::scene::Mesh;

#[test]
fn coverage_rejects_invalid_ranges_and_custom_shader_bypass() {
    for coverage in [[-0.1, 1.], [0., 1.1], [0.8, 0.2], [f32::NAN, 1.]] {
        let mesh = Mesh {
            coverage,
            ..Default::default()
        };
        assert!(mesh.validate_material().is_err());
    }
    for coverage in [[0., 0.], [0., 1.], [0.5, 1.]] {
        assert!(
            Mesh {
                coverage,
                ..Default::default()
            }
            .validate_material()
            .is_ok()
        );
    }
    assert!(
        Mesh {
            coverage: [0., 0.5],
            material_shader: Some([1, 1, 1, 1]),
            ..Default::default()
        }
        .validate_material()
        .is_err()
    );
}
