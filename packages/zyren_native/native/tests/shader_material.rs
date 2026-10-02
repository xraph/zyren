use serde_json::{Value, json};
use zyren_runtime::renderer::Renderer;

fn command(renderer: &mut Renderer, command: Value) -> Value {
    let bytes = serde_json::to_vec(&json!({"version":1,"request":1,"command":command})).unwrap();
    serde_json::from_slice(&renderer.graph_command(&bytes, 256 * 1024).unwrap()).unwrap()
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn malformed_material_commands_preserve_the_graph_device() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let result = command(
        &mut renderer,
        json!({"operation":"compileMaterial", "description":{
            "label":"invalid", "inputs":[], "resources":[], "passes":[]
        }}),
    );
    assert_eq!(result["error"]["code"], "invalidDescriptor");
    let stats = command(&mut renderer, json!({"operation":"stats"}));
    assert_eq!(stats["result"]["liveMaterials"], 0);
    assert_eq!(stats["result"]["liveGraphs"], 0);
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn screen_storage_outputs_validate_native_access_and_retain_resources() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let packet = |op: u32, body: &[u8]| {
        [
            2_u32.to_le_bytes().as_slice(),
            op.to_le_bytes().as_slice(),
            1_u64.to_le_bytes().as_slice(),
            (body.len() as u64).to_le_bytes().as_slice(),
            body,
        ]
        .concat()
    };
    let resource = renderer
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
    let texture = json!(
        resource[24..]
            .chunks_exact(8)
            .map(|v| u64::from_le_bytes(v.try_into().unwrap()))
            .collect::<Vec<_>>()
    );
    let shader_request = json!({"version":1,"request":1,"command":{"operation":"compile","label":"auxiliary","source":r"
@group(1) @binding(0) var auxiliary:texture_storage_2d<rgba8unorm,write>;
@vertex fn vertex(@builtin(vertex_index) i:u32)->@builtin(position) vec4<f32>{return vec4<f32>(0.,0.,0.,1.);}
@fragment fn fragment(@builtin(position) p:vec4<f32>)->@location(0) vec4<f32>{
 textureStore(auxiliary,vec2<i32>(p.xy),vec4<f32>(1.));return vec4<f32>(0.);
}"}});
    let shader: Value = serde_json::from_slice(
        &renderer
            .shader_command(&serde_json::to_vec(&shader_request).unwrap(), 256 * 1024)
            .unwrap(),
    )
    .unwrap();
    let program = shader["result"]["key"].clone();
    let description = json!({"label":"auxiliary","resources":[{"key":texture,"label":"auxiliary"}],"inputs":[],"passes":[{
        "kind":"material","name":"auxiliary","program":program,"screenSpace":true,"requiresUv":false,
        "vertexEntryPoint":"vertex","fragmentEntryPoint":"fragment","after":[],"reads":[],"writes":[texture],
        "bindings":[{"kind":"storageTexture","group":1,"binding":0,"key":texture,"stages":[1],"mipLevel":0,"mipLevels":1}]
    }]});
    let compile =
        |description: Value| json!({"operation":"compileMaterial","description":description});
    for (field, value, code) in [
        ("screenSpace", json!(false), "invalidDescriptor"),
        ("writes", json!([]), "accessMismatch"),
        ("reads", json!([texture]), "accessMismatch"),
    ] {
        let mut bad = description.clone();
        bad["passes"][0][field] = value;
        assert_eq!(command(&mut renderer, compile(bad))["error"]["code"], code);
    }
    for (field, value) in [
        ("group", json!(0)),
        ("stages", json!([0])),
        ("kind", json!("storageReadWrite")),
    ] {
        let mut bad = description.clone();
        bad["passes"][0]["bindings"][0][field] = value;
        assert_eq!(
            command(&mut renderer, compile(bad))["error"]["code"],
            "invalidDescriptor"
        );
    }
    let mut alias = description.clone();
    let mut sampled = alias["passes"][0]["bindings"][0].clone();
    sampled["binding"] = json!(1);
    sampled["kind"] = json!("sampled");
    alias["passes"][0]["bindings"]
        .as_array_mut()
        .unwrap()
        .push(sampled);
    assert_eq!(
        command(&mut renderer, compile(alias))["error"]["code"],
        "aliasConflict"
    );
    assert_eq!(
        command(&mut renderer, json!({"operation":"stats"}))["result"]["liveMaterials"],
        0
    );
    let result = command(&mut renderer, compile(description));
    let material = result["result"]["key"].clone();
    assert!(!material.is_null(), "{result}");
    renderer
        .resource_command(&packet(6, &resource[24..]), 24)
        .unwrap();
    command(
        &mut renderer,
        json!({"operation":"releaseMaterial","key":material}),
    );
    assert!(
        renderer
            .resource_command(&packet(5, &resource[24..]), 24)
            .is_err()
    );
    assert_eq!(
        command(&mut renderer, json!({"operation":"stats"}))["result"]["liveMaterials"],
        0
    );
}
