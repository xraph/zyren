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
            let memory = &result["memoryReports"][0];
            assert_eq!(memory["status"], "available");
            assert_eq!(memory["scope"], "processDevice");
            assert_eq!(memory["source"], "metal.deviceMemory");
            assert!(memory["usageBytes"].as_u64().unwrap() > 0);
            assert!(memory["recommendedMaxWorkingSetBytes"].as_u64().unwrap() > 0);
            assert!(memory["budgetBytes"].is_null());
            assert_eq!(memory["usageIsEstimate"], false);
            assert_eq!(
                result["deviceAllocationSource"],
                "metal.currentAllocatedSize"
            );
            assert!(result["deviceAllocatedBytes"].as_u64().unwrap() > 0);
        } else {
            assert!(result["deviceAllocatedBytes"].is_null());
            let reports = result["memoryReports"].as_array().unwrap();
            assert!(!reports.is_empty());
            for report in reports {
                if report["status"] == "available" {
                    assert!(report["usageBytes"].is_u64());
                    assert!(report["budgetBytes"].is_u64());
                    assert!(report["recommendedMaxWorkingSetBytes"].is_null());
                } else {
                    assert!(report["reason"].is_string());
                    assert!(report["usageBytes"].is_null());
                    assert!(report["budgetBytes"].is_null());
                }
            }
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
