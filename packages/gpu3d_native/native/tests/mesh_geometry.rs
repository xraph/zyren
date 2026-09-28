use gpu3d_runtime::{renderer::Renderer, resources::registry::ResourceKey, scene::Frame};
use serde_json::{Value, json};

const CAPACITY: usize = 256 * 1024;
fn request(command: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"version":1,"request":1,"command":command})).unwrap()
}
fn graph(renderer: &mut Renderer, command: Value) -> Value {
    serde_json::from_slice(&renderer.graph_command(&request(command), CAPACITY).unwrap()).unwrap()
}

#[test]
#[ignore = "requires a native GPU"]
fn profile_and_binding_rejection_preserve_shader_ownership_and_device() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let module: Value = serde_json::from_slice(&renderer.shader_command(&request(json!({
        "operation":"compile", "label":"geometry admission", "source": r#"
        @vertex fn vertex(@location(0) p: vec3<f32>) -> @builtin(position) vec4<f32> { return vec4(p,1.); }
        @fragment fn fragment() -> @location(0) vec4<f32> { return vec4(1.,0.,0.,1.); }
        "#
    })), CAPACITY).unwrap()).unwrap();
    let descriptor = json!({"program": module["result"]["key"], "label":"geometry admission",
        "bindings":[], "vertexLayout":0, "geometry":2, "vertexEntryPoint":"vertex", "fragmentEntryPoint":"fragment"});
    for (field, value, code) in [
        ("geometry", json!(4), "limitExceeded"),
        ("vertexLayout", json!(6), "limitExceeded"),
        (
            "bindings",
            json!([{"kind":"uniform","group":2,"binding":0,"stages":[0],"key":[0,0,0,0],"offset":0,"size":16}]),
            "invalidBinding",
        ),
    ] {
        let mut bad = descriptor.clone();
        bad[field] = value;
        assert_eq!(
            graph(
                &mut renderer,
                json!({"operation":"compileMesh","description":bad})
            )["error"]["code"],
            code
        );
        assert_eq!(
            graph(&mut renderer, json!({"operation":"stats"}))["result"]["liveMeshShaders"],
            0
        );
    }
    let compiled = graph(
        &mut renderer,
        json!({"operation":"compileMesh","description":descriptor}),
    );
    let key: [u64; 4] = serde_json::from_value(compiled["result"]["key"].clone()).unwrap();
    let mut frame: Frame = serde_json::from_value(json!({"version":1,
        "view_projection": glam::Mat4::IDENTITY.to_cols_array(), "background":[0,0,0], "light_direction":[0,0,1], "ambient":0,
        "geometries":[{"id":1,"positions":[[-0.5,-0.5,0.4],[0.5,-0.5,0.4],[0,0.5,0.4]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),"color":[1,0,0],"unlit":true}]
    })).unwrap();
    frame.meshes[0].shader = Some(ResourceKey {
        renderer: key[0],
        device_generation: key[1],
        slot: key[2],
        slot_generation: key[3],
    });
    assert!(
        renderer
            .render(&frame, 17, 17)
            .unwrap_err()
            .contains("does not match")
    );
    frame.meshes[0].shader = None;
    let pixels = renderer.render(&frame, 17, 17).unwrap();
    assert!(pixels.chunks_exact(4).any(|p| p[0] == 255));
    assert!(graph(&mut renderer, json!({"operation":"releaseMesh","key":key}))["error"].is_null());
    assert_eq!(
        graph(&mut renderer, json!({"operation":"stats"}))["result"]["liveMeshShaders"],
        0
    );
}
