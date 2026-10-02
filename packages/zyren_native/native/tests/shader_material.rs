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
