use zyren_runtime::{renderer::Renderer, resources::ResourceError};
use serde_json::{Value, json};
const CAPACITY: usize = 256 * 1024;
fn request(command: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"version": 1, "request": 7, "command": command})).unwrap()
}
fn graph(renderer: &mut Renderer, command: Value) -> Value {
    let response: Value =
        serde_json::from_slice(&renderer.graph_command(&request(command), CAPACITY).unwrap())
            .unwrap();
    assert_eq!(response["request"], 7);
    response
}
fn packet(op: u32, body: &[u8]) -> Vec<u8> {
    [
        2_u32.to_le_bytes().as_slice(),
        op.to_le_bytes().as_slice(),
        1_u64.to_le_bytes().as_slice(),
        (body.len() as u64).to_le_bytes().as_slice(),
        body,
    ]
    .concat()
}
fn keys(bytes: &[u8]) -> Vec<u64> {
    bytes
        .chunks_exact(8)
        .map(|bytes| u64::from_le_bytes(bytes.try_into().unwrap()))
        .collect()
}
fn bytes(value: &Value) -> Vec<u8> {
    value
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|v| v.as_u64().unwrap().to_le_bytes())
        .collect()
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn native_graph_validation_retains_owners_and_rejects_forged_access() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let texture = renderer
        .resource_command(
            &packet(
                3,
                &[4_u32, 4, 1, 0, 21, 0]
                    .into_iter()
                    .flat_map(u32::to_le_bytes)
                    .collect::<Vec<_>>(),
            ),
            56,
        )
        .unwrap();
    let texture_key = json!(keys(&texture[24..]));
    let shader: Value = serde_json::from_slice(
        &renderer
            .shader_command(
                &request(json!({"operation": "compile", "label": "fill", "source": "
      @group(0) @binding(0) var output: texture_storage_2d<rgba8unorm, write>;
      @compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
        textureStore(output, vec2<i32>(id.xy), vec4<f32>(1., 0., 0., 1.));
      }"})),
                CAPACITY,
            )
            .unwrap(),
    )
    .unwrap();
    let shader_key = shader["result"]["key"].clone();
    let description = json!({"label": "test", "inputs": [], "resources": [{"key": texture_key, "label": "output"}], "passes": [{
      "kind": "compute", "name": "fill", "program": shader_key, "after": [], "entryPoint": "main", "workgroups": [4, 4, 1],
      "bindings": [{"kind": "storageTexture", "key": texture_key, "group": 0, "binding": 0, "stages": [2], "mipLevel": 0, "mipLevels": 1}],
      "reads": [], "writes": [texture_key]}]});
    let compile = |description: Value| json!({"operation": "compile", "description": description});
    for index in [1, 2, usize::MAX] {
        let mut bad = description.clone();
        bad["scenePassIndex"] = json!(index);
        assert_eq!(
            graph(&mut renderer, compile(bad))["error"]["code"],
            "invalidDescriptor"
        );
    }
    let scene = renderer
        .resource_command(
            &packet(
                3,
                &[4_u32, 4, 1, 0, 23, 0]
                    .into_iter()
                    .flat_map(u32::to_le_bytes)
                    .collect::<Vec<_>>(),
            ),
            56,
        )
        .unwrap();
    let scene_key = json!(keys(&scene[24..]));
    for read in [false, true] {
        let mut bad = description.clone();
        bad["scenePassIndex"] = json!(1);
        bad["sceneColor"] = scene_key.clone();
        bad["output"] = scene_key.clone();
        bad["resources"] = json!([{ "key": scene_key, "label": "scene" }]);
        bad["inputs"] = json!([scene_key]);
        bad["passes"][0]["bindings"][0]["key"] = scene_key.clone();
        bad["passes"][0]["writes"] = if read { json!([]) } else { json!([scene_key]) };
        if read {
            bad["passes"][0]["bindings"][0]["kind"] = json!("sampled");
            bad["passes"][0]["reads"] = json!([scene_key]);
        }
        assert_eq!(
            graph(&mut renderer, compile(bad))["error"]["code"],
            "invalidDescriptor"
        );
    }
    renderer
        .resource_command(&packet(6, &scene[24..]), 24)
        .unwrap();
    assert!(
        renderer
            .graph_command(&request(compile(description.clone())), CAPACITY - 1)
            .is_err()
    );
    assert_eq!(
        graph(&mut renderer, json!({"operation": "stats"}))["result"]["liveGraphs"],
        0
    );
    for (field, value, code) in [
        ("reads", json!([texture_key]), "accessMismatch"),
        ("after", json!(["later"]), "missingDependency"),
        ("program", texture_key.clone(), "closedResource"),
        ("workgroups", json!([0, 1, 1]), "limitExceeded"),
    ] {
        let mut bad = description.clone();
        bad["passes"][0][field] = value;
        assert_eq!(graph(&mut renderer, compile(bad))["error"]["code"], code);
    }
    let mut bad = description.clone();
    bad["passes"][0]["bindings"][0]["group"] = json!(u32::MAX);
    assert_eq!(
        graph(&mut renderer, compile(bad))["error"]["code"],
        "invalidBinding"
    );
    let mut bad = description.clone();
    let mut sampled = bad["passes"][0]["bindings"][0].clone();
    sampled["kind"] = json!("sampled");
    sampled["binding"] = json!(1);
    bad["passes"][0]["bindings"]
        .as_array_mut()
        .unwrap()
        .push(sampled.clone());
    bad["passes"][0]["reads"] = json!([texture_key]);
    assert_eq!(
        graph(&mut renderer, compile(bad))["error"]["code"],
        "aliasConflict"
    );
    let mut bad = description.clone();
    bad["passes"][0]["bindings"] = json!([sampled]);
    bad["passes"][0]["reads"] = json!([texture_key]);
    bad["passes"][0]["writes"] = json!([]);
    assert_eq!(
        graph(&mut renderer, compile(bad))["error"]["code"],
        "uninitializedRead"
    );
    for (scene, output, code) in [
        (texture_key.clone(), Value::Null, "invalidDescriptor"),
        (Value::Null, texture_key.clone(), "invalidDescriptor"),
        (texture_key.clone(), texture_key.clone(), "invalidBinding"),
        (shader_key.clone(), texture_key.clone(), "invalidDescriptor"),
    ] {
        let mut candidate = description.clone();
        candidate["sceneColor"] = scene;
        candidate["output"] = output;
        assert_eq!(
            graph(&mut renderer, compile(candidate))["error"]["code"],
            code
        );
    }
    let built = graph(&mut renderer, compile(description.clone()));
    let key = built["result"]["key"].clone();
    assert!(!key.is_null(), "{built}");
    let mut bad = description;
    bad["passes"][0]["bindings"][0]["binding"] = json!(1);
    let error = graph(&mut renderer, compile(bad));
    assert_eq!(error["error"]["code"], "pipelineFailed", "{error}");
    assert_eq!(error["error"]["passName"], "fill");
    assert_eq!(
        graph(&mut renderer, json!({"operation": "stats"}))["result"]["cachedPipelines"],
        1
    );
    renderer
        .resource_command(&packet(6, &texture[24..]), 24)
        .unwrap();
    renderer
        .shader_command(
            &request(json!({"operation": "release", "key": shader_key})),
            CAPACITY,
        )
        .unwrap();
    assert_eq!(
        graph(&mut renderer, json!({"operation": "execute", "key": key}))["result"]["dispatches"],
        1
    );
    let pixels = renderer
        .resource_command(
            &packet(
                9,
                &[bytes(&texture_key), 0_u32.to_le_bytes().to_vec()].concat(),
            ),
            88,
        )
        .unwrap();
    assert!(
        pixels[24..]
            .chunks_exact(4)
            .all(|pixel| pixel == [255, 0, 0, 255])
    );
    graph(&mut renderer, json!({"operation": "release", "key": key}));
    assert_eq!(
        graph(&mut renderer, json!({"operation": "execute", "key": key}))["error"]["code"],
        "closedResource"
    );
    assert_eq!(
        renderer.resource_command(&packet(5, &texture[24..]), 24),
        Err(ResourceError::StaleKey)
    );
    let stats = graph(&mut renderer, json!({"operation": "stats"}));
    assert_eq!(stats["result"]["liveGraphs"], 0);
    assert_eq!(stats["result"]["cachedPipelines"], 0);
    assert!(
        renderer
            .graph_command(
                &request(json!({"operation": "stats", "unknown": 0})),
                CAPACITY
            )
            .is_err()
    );
}

#[test]
fn graph_ffi_checks_output_capacity_and_lengths_before_access() {
    let input = request(json!({"operation": "stats"}));
    let mut output = vec![0; CAPACITY];
    let mut written = 99;
    for (pointer, length, capacity) in [
        (std::ptr::null(), 0, CAPACITY),
        (input.as_ptr(), usize::MAX, CAPACITY),
        (input.as_ptr(), input.len(), CAPACITY - 1),
        (input.as_ptr(), input.len(), CAPACITY),
    ] {
        assert_ne!(
            unsafe {
                zyren_runtime::fg2_graph_command(
                    0,
                    pointer,
                    length,
                    output.as_mut_ptr(),
                    capacity,
                    &mut written,
                )
            },
            0
        );
        assert_eq!(written, 0);
    }
}
