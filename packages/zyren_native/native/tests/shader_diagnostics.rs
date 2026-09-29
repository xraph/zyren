use zyren_runtime::renderer::Renderer;
use serde_json::{Value, json};

const CAPACITY: usize = 256 * 1024;
const VALID: &str = "@compute @workgroup_size(8, 4, 1) fn main() {}";

fn packet(command: Value) -> Vec<u8> {
    serde_json::to_vec(&json!({"version": 1, "request": 31, "command": command})).unwrap()
}
fn send(renderer: &mut Renderer, command: Value) -> Value {
    let response = renderer.shader_command(&packet(command), CAPACITY).unwrap();
    let response: Value = serde_json::from_slice(&response).unwrap();
    assert_eq!(response["version"], 1);
    assert_eq!(response["request"], 31);
    response
}
fn compile(renderer: &mut Renderer, source: &str) -> Value {
    send(
        renderer,
        json!({"operation": "compile", "source": source, "label": "test"}),
    )
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn shader_errors_recover_and_cache_lifetime_is_scoped() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let source = "// 🌍\n@compute @workgroup_size(1) fn main() { let a: f32 = true; }";
    let invalid = compile(&mut renderer, source);
    assert_eq!(invalid["error"]["code"], "invalidSource", "{invalid}");
    let diagnostic = &invalid["error"]["diagnostics"][0];
    assert_eq!(diagnostic["severity"], "error");
    assert_eq!(diagnostic["location"]["line"], 2, "{diagnostic}");
    let offset = diagnostic["location"]["offset"].as_u64().unwrap() as usize;
    assert!(offset >= "// 🌍\n".encode_utf16().count());
    let syntax = compile(
        &mut renderer,
        "// 🌍\n@compute @workgroup_size(1) fn main() { /* 🦀 */ ? }",
    );
    let location = &syntax["error"]["diagnostics"][0]["location"];
    let prefix = "// 🌍\n@compute @workgroup_size(1) fn main() { /* 🦀 */ ";
    assert_eq!(location["offset"], prefix.encode_utf16().count());
    assert_eq!(
        location["column"],
        prefix
            .split('\n')
            .next_back()
            .unwrap()
            .encode_utf16()
            .count()
            + 1
    );
    let first = compile(&mut renderer, VALID);
    let second = compile(&mut renderer, VALID);
    assert_eq!(
        first["result"]["entryPoints"][0]["workgroupSize"],
        json!([8, 4, 1])
    );
    let a = first["result"]["key"].clone();
    let b = second["result"]["key"].clone();
    assert_ne!(a, b);
    let stats = send(&mut renderer, json!({"operation": "stats"}));
    assert_eq!(stats["result"]["livePrograms"], 2);
    assert_eq!(stats["result"]["cachedModules"], 1);
    assert_eq!(stats["result"]["cacheHits"], 1);
    assert_eq!(stats["result"]["residentSourceBytes"], VALID.len() * 2);
    send(&mut renderer, json!({"operation": "retain", "key": a}));
    for key in [&a, &b, &a] {
        assert!(
            send(&mut renderer, json!({"operation": "release", "key": key}))["error"].is_null()
        );
    }
    let stats = send(&mut renderer, json!({"operation": "stats"}));
    assert_eq!(stats["result"]["livePrograms"], 0);
    assert_eq!(stats["result"]["cachedModules"], 0);
    assert_eq!(stats["result"]["residentSourceBytes"], 0);
    assert_eq!(
        send(&mut renderer, json!({"operation": "retain", "key": a}))["error"]["code"],
        "staleProgram"
    );
    assert!(!compile(&mut renderer, VALID)["result"]["key"].is_null());
    let stages = compile(
        &mut renderer,
        "
        @vertex fn vs() -> @builtin(position) vec4<f32> { return vec4<f32>(0., 0., 0., 1.); }
        @fragment fn fs() -> @location(0) vec4<f32> { return vec4<f32>(1.); }
        override size: u32 = 4;
        @compute @workgroup_size(size) fn cs() {}
    ",
    );
    let entries = stages["result"]["entryPoints"].as_array().unwrap();
    assert_eq!(
        entries
            .iter()
            .map(|e| e["stage"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["vertex", "fragment", "compute"]
    );
    assert!(entries.iter().all(|e| e["workgroupSize"].is_null()));
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn shader_admission_checks_capacity_and_foreign_handles_before_mutation() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let request = packet(json!({"operation": "compile", "source": VALID, "label": "bounded"}));
    assert!(renderer.shader_command(&request, CAPACITY - 1).is_err());
    assert!(renderer.shader_command(b"{}", CAPACITY).is_err());
    assert_eq!(
        send(&mut renderer, json!({"operation": "stats"}))["result"]["livePrograms"],
        0
    );
    let mut other = pollster::block_on(Renderer::new()).unwrap();
    let key = compile(&mut renderer, VALID)["result"]["key"].clone();
    assert_eq!(
        send(&mut other, json!({"operation": "retain", "key": key}))["error"]["code"],
        "staleProgram"
    );
    assert_eq!(
        compile(&mut renderer, &" ".repeat(1024 * 1024 + 1))["error"]["code"],
        "limitExceeded"
    );
    assert_eq!(
        send(&mut renderer, json!({"operation": "stats"}))["result"]["livePrograms"],
        1
    );
}

#[test]
fn shader_ffi_bounds_and_nulls_fail_before_reading_input() {
    use zyren_runtime::fg2_shader_command;
    let bytes = packet(json!({"operation": "stats"}));
    let mut output = vec![0; CAPACITY];
    let mut written = 99;
    for (input, length, capacity) in [
        (std::ptr::null(), 0, CAPACITY),
        (bytes.as_ptr(), usize::MAX, CAPACITY),
        (bytes.as_ptr(), bytes.len(), CAPACITY - 1),
        (bytes.as_ptr(), bytes.len(), CAPACITY),
    ] {
        assert_ne!(
            unsafe {
                fg2_shader_command(
                    0,
                    input,
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

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn shader_limits_and_resource_namespaces_are_independent() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let buffer_request = [
        2_u32.to_le_bytes().as_slice(),
        1_u32.to_le_bytes().as_slice(),
        1_u64.to_le_bytes().as_slice(),
        16_u64.to_le_bytes().as_slice(),
        16_u64.to_le_bytes().as_slice(),
        48_u32.to_le_bytes().as_slice(),
        0_u32.to_le_bytes().as_slice(),
    ]
    .concat();
    let buffer_response = renderer.resource_command(&buffer_request, 56).unwrap();
    let buffer_key: Vec<u64> = buffer_response[24..]
        .chunks_exact(8)
        .map(|bytes| u64::from_le_bytes(bytes.try_into().unwrap()))
        .collect();
    let mut keys = Vec::new();
    for _ in 0..256 {
        keys.push(compile(&mut renderer, VALID)["result"]["key"].clone());
    }
    assert_eq!(
        compile(&mut renderer, VALID)["error"]["code"],
        "limitExceeded"
    );
    let shader_key = keys[0].as_array().unwrap();
    assert_eq!(shader_key[2], buffer_key[2]);
    assert_eq!(shader_key[3], buffer_key[3]);
    assert_ne!(shader_key[0], buffer_key[0]);
    assert_eq!(
        send(
            &mut renderer,
            json!({"operation": "retain", "key": buffer_key})
        )["error"]["code"],
        "staleProgram"
    );
    let key_bytes: Vec<u8> = shader_key
        .iter()
        .flat_map(|v| v.as_u64().unwrap().to_le_bytes())
        .collect();
    let resource_packet = [
        2_u32.to_le_bytes().as_slice(),
        5_u32.to_le_bytes().as_slice(),
        1_u64.to_le_bytes().as_slice(),
        32_u64.to_le_bytes().as_slice(),
        &key_bytes,
    ]
    .concat();
    assert_eq!(
        renderer.resource_command(&resource_packet, 24),
        Err(zyren_runtime::resources::ResourceError::StaleKey)
    );
    for key in &keys {
        send(&mut renderer, json!({"operation": "release", "key": key}));
    }
    let oversized_label = send(
        &mut renderer,
        json!({"operation": "compile", "source": VALID, "label": "é".repeat(513)}),
    );
    assert_eq!(oversized_label["error"]["code"], "limitExceeded");
    let request =
        json!({"version": 1, "request": 1, "command": {"operation": "stats", "extra": true}});
    assert!(
        renderer
            .shader_command(&serde_json::to_vec(&request).unwrap(), CAPACITY)
            .is_err()
    );
    for _ in 0..16 {
        let source = format!("{}{}", VALID, " ".repeat(1024 * 1024 - VALID.len()));
        assert!(!compile(&mut renderer, &source)["result"]["key"].is_null());
    }
    assert_eq!(
        compile(&mut renderer, VALID)["error"]["code"],
        "limitExceeded"
    );
    let stats = send(&mut renderer, json!({"operation": "stats"}));
    assert_eq!(stats["result"]["residentSourceBytes"], 16 * 1024 * 1024);
    assert_eq!(stats["result"]["livePrograms"], 16);
}
