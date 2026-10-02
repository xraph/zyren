use serde_json::{Value, json};
use zyren_runtime::renderer::Renderer;
fn inspect(renderer: &mut Renderer, limit: usize) -> Value {
    let bytes = serde_json::to_vec(&json!({"version":1,"request":1,
        "command":{"operation":"inspectGpu","allocation_limit":limit}}))
    .unwrap();
    serde_json::from_slice(&renderer.graph_command(&bytes, 256 * 1024).unwrap()).unwrap()
}
#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn inspection_is_bounded_read_only_and_never_invents_residency() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let info = serde_json::to_vec(&json!({"version":1,"request":1,
        "command":{"operation":"deviceInfo"}}))
    .unwrap();
    let info: Value =
        serde_json::from_slice(&renderer.graph_command(&info, 256 * 1024).unwrap()).unwrap();
    assert!(info["result"]["gpuTimestampQueries"].is_boolean());
    let before = inspect(&mut renderer, 1);
    assert!(before["result"]["residentBytes"].is_null());
    assert!(before["result"]["lastSubmissionGpuTimeNs"].is_null());
    assert_eq!(before["result"]["submittedFrames"], 0);
    let body = [
        16_u64.to_le_bytes().as_slice(),
        32_u32.to_le_bytes().as_slice(),
        0_u32.to_le_bytes().as_slice(),
    ]
    .concat();
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
    let a = renderer.resource_command(&packet(1, &body), 56).unwrap();
    let b = renderer.resource_command(&packet(1, &body), 56).unwrap();
    let readbacks = renderer.counters().readback_bytes;
    for _ in 0..3 {
        let result = inspect(&mut renderer, 1)["result"].clone();
        assert_eq!(result["totalAllocations"], 2);
        assert_eq!(result["registryPayloadBytes"], 32);
        assert_eq!(result["allocations"].as_array().unwrap().len(), 1);
        assert_eq!(result["allocations"][0]["references"], 1);
        assert!(result["residentBytes"].is_null());
        if renderer.backend == wgpu::Backend::Metal {
            assert_eq!(
                result["deviceAllocationSource"],
                "metal.currentAllocatedSize"
            );
            assert!(result["deviceAllocatedBytes"].as_u64().unwrap() > 0);
        } else {
            assert!(result["deviceAllocatedBytes"].is_null());
        }
    }
    assert_eq!(renderer.counters().readback_bytes, readbacks);
    assert_eq!(
        inspect(&mut renderer, 257)["error"]["code"],
        "limitExceeded"
    );
    for reply in [a, b] {
        renderer
            .resource_command(&packet(6, &reply[24..]), 24)
            .unwrap();
    }
    assert_eq!(inspect(&mut renderer, 256)["result"]["totalAllocations"], 0);
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn completed_frame_timing_does_not_count_as_pixel_readback() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let frame = serde_json::from_value(json!({
        "version":1,"view_projection":glam::Mat4::IDENTITY.to_cols_array(),
        "background":[1,0,0],"light_direction":[0,0,1],"ambient":0.2,
        "geometries":[],"meshes":[]
    }))
    .unwrap();
    let info = serde_json::to_vec(&json!({"version":1,"request":1,
        "command":{"operation":"deviceInfo"}}))
    .unwrap();
    let info: Value =
        serde_json::from_slice(&renderer.graph_command(&info, 256 * 1024).unwrap()).unwrap();
    let queries = info["result"]["gpuTimestampQueries"].as_bool().unwrap();
    assert_eq!(
        info["result"]["gpuTimestampBufferBytes"],
        if queries { 32 } else { 0 }
    );
    for frame_index in 1..=32 {
        assert_eq!(renderer.render(&frame, 8, 8).unwrap().len(), 256);
        let result = inspect(&mut renderer, 1)["result"].clone();
        assert_eq!(result["submittedFrames"], frame_index);
        let source = result["gpuTimeSource"].as_str().unwrap();
        if queries || renderer.backend == wgpu::Backend::Metal {
            assert!(result["lastSubmissionGpuTimeNs"].as_u64().is_some());
            assert_eq!(
                source,
                if queries {
                    "wgpu.timestampQuery.commandEncoder"
                } else {
                    "metal.commandBuffer.startEndTime"
                }
            );
        } else {
            assert!(result["lastSubmissionGpuTimeNs"].is_null());
            assert_eq!(source, "unavailable");
        }
        assert_eq!(inspect(&mut renderer, 1)["result"], result);
        assert_eq!(renderer.counters().readback_bytes, frame_index * 256);
    }
}
