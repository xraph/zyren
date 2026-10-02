//! On-demand memory accounting. None of these APIs measures physical residency.
use serde::Serialize;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MemoryReport {
    status: &'static str,
    source: &'static str,
    scope: &'static str,
    region: &'static str,
    heap_index: Option<u32>,
    node_index: Option<u32>,
    device_local: Option<bool>,
    unified_memory: Option<bool>,
    usage_bytes: Option<u64>,
    budget_bytes: Option<u64>,
    recommended_max_working_set_bytes: Option<u64>,
    usage_is_estimate: bool,
    budget_is_estimate: bool,
    reason: Option<String>,
}

impl MemoryReport {
    fn new(source: &'static str, scope: &'static str, region: &'static str) -> Self {
        Self {
            status: "available",
            source,
            scope,
            region,
            heap_index: None,
            node_index: None,
            device_local: None,
            unified_memory: None,
            usage_bytes: None,
            budget_bytes: None,
            recommended_max_working_set_bytes: None,
            usage_is_estimate: false,
            budget_is_estimate: false,
            reason: None,
        }
    }

    fn unavailable(mut self, status: &'static str, reason: impl Into<String>) -> Self {
        self.status = status;
        self.reason = Some(reason.into());
        self
    }
}

pub(crate) fn inspect(device: &wgpu::Device) -> Vec<MemoryReport> {
    #[cfg(target_vendor = "apple")]
    // SAFETY: query the existing device without mutation or escaping its HAL borrow.
    if let Some(hal) = unsafe { device.as_hal::<wgpu::hal::api::Metal>() } {
        use objc2::runtime::NSObjectProtocol;
        use objc2_metal::MTLDevice;
        let raw = hal.raw_device();
        let mut report = MemoryReport::new("metal.deviceMemory", "processDevice", "device");
        report.usage_bytes = Some(raw.currentAllocatedSize() as u64);
        report.unified_memory = Some(raw.hasUnifiedMemory());
        // This selector arrived on iOS 16, later than our iOS 13 floor.
        if raw.respondsToSelector(objc2::sel!(recommendedMaxWorkingSetSize)) {
            report.recommended_max_working_set_bytes = Some(raw.recommendedMaxWorkingSetSize());
        }
        return vec![report];
    }
    #[cfg(not(target_vendor = "apple"))]
    // SAFETY: only read memory properties from this device's physical adapter.
    if let Some(hal) = unsafe { device.as_hal::<wgpu::hal::api::Vulkan>() } {
        return vulkan(&hal);
    }
    #[cfg(windows)]
    // SAFETY: no resource/device mutation, and COM references remain local to this query.
    if let Some(hal) = unsafe { device.as_hal::<wgpu::hal::api::Dx12>() } {
        return dx12(hal.raw_device());
    }
    vec![
        MemoryReport::new("unavailable", "unknown", "device")
            .unavailable("unsupported", "backendUnsupported"),
    ]
}

#[cfg(not(target_vendor = "apple"))]
fn vulkan(device: &wgpu::hal::vulkan::Device) -> Vec<MemoryReport> {
    use ash::{ext, khr, vk};
    let unsupported = |reason| {
        vec![
            MemoryReport::new("vulkan.EXT_memory_budget", "processHeap", "heap")
                .unavailable("unsupported", reason),
        ]
    };
    if !device
        .enabled_device_extensions()
        .contains(&ext::memory_budget::NAME)
    {
        return unsupported("memoryBudgetExtensionUnavailable");
    }
    let shared = device.shared_instance();
    let instance = shared.raw_instance();
    let mut budget = vk::PhysicalDeviceMemoryBudgetPropertiesEXT::default();
    let mut properties = vk::PhysicalDeviceMemoryProperties2::default().push_next(&mut budget);
    // SAFETY: stack-owned output structures, valid adapter and negotiated entry point.
    unsafe {
        if shared.instance_api_version() >= vk::API_VERSION_1_1 {
            instance.get_physical_device_memory_properties2(
                device.raw_physical_device(),
                &mut properties,
            );
        } else if shared
            .extensions()
            .contains(&khr::get_physical_device_properties2::NAME)
        {
            let extension =
                khr::get_physical_device_properties2::Instance::new(shared.entry(), instance);
            extension.get_physical_device_memory_properties2(
                device.raw_physical_device(),
                &mut properties,
            );
        } else {
            return unsupported("memoryProperties2Unavailable");
        }
    }
    let memory = properties.memory_properties;
    (0..memory.memory_heap_count.min(vk::MAX_MEMORY_HEAPS as u32))
        .map(|index| {
            let mut report = MemoryReport::new("vulkan.EXT_memory_budget", "processHeap", "heap");
            report.heap_index = Some(index);
            report.device_local = Some(
                memory.memory_heaps[index as usize]
                    .flags
                    .contains(vk::MemoryHeapFlags::DEVICE_LOCAL),
            );
            report.usage_bytes = Some(budget.heap_usage[index as usize]);
            report.budget_bytes = Some(budget.heap_budget[index as usize]);
            report.usage_is_estimate = true;
            report.budget_is_estimate = true;
            report
        })
        .collect()
}

#[cfg(windows)]
fn dx12(device: &windows::Win32::Graphics::Direct3D12::ID3D12Device) -> Vec<MemoryReport> {
    use windows::Win32::Graphics::Dxgi::*;
    let base =
        |region| MemoryReport::new("dxgi.QueryVideoMemoryInfo", "processAdapterSegment", region);
    // Resolve this device's LUID, never the default/first adapter in the system.
    // SAFETY: valid COM device and stack-local output references.
    let adapter = unsafe {
        CreateDXGIFactory1::<IDXGIFactory4>()
            .and_then(|factory| factory.EnumAdapterByLuid::<IDXGIAdapter3>(device.GetAdapterLuid()))
    };
    let adapter = match adapter {
        Ok(adapter) => adapter,
        Err(error) => {
            return vec![base("adapter").unavailable(
                "error",
                format!("adapterQueryFailed:0x{:08x}", error.code().0 as u32),
            )];
        }
    };
    // D3D12 supports at most 32 linked nodes. Keep the diagnostic response bounded.
    let nodes = unsafe { device.GetNodeCount() }.min(32);
    let mut reports = Vec::with_capacity(nodes as usize * 2);
    for node in 0..nodes {
        for (region, group) in [
            ("local", DXGI_MEMORY_SEGMENT_GROUP_LOCAL),
            ("nonLocal", DXGI_MEMORY_SEGMENT_GROUP_NON_LOCAL),
        ] {
            let mut report = base(region);
            report.node_index = Some(node);
            report.device_local = Some(group == DXGI_MEMORY_SEGMENT_GROUP_LOCAL);
            let mut info = DXGI_QUERY_VIDEO_MEMORY_INFO::default();
            // A failure in one segment must not discard measurements from the other.
            match unsafe { adapter.QueryVideoMemoryInfo(node, group, &mut info) } {
                Ok(()) => {
                    report.usage_bytes = Some(info.CurrentUsage);
                    report.budget_bytes = Some(info.Budget);
                }
                Err(error) => {
                    report = report.unavailable(
                        "error",
                        format!("memoryQueryFailed:0x{:08x}", error.code().0 as u32),
                    )
                }
            }
            reports.push(report);
        }
    }
    reports
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unavailable_measurements_stay_null_and_distinct_from_zero() {
        let unavailable = MemoryReport::new("test", "processHeap", "heap")
            .unavailable("unsupported", "missingExtension");
        let json = serde_json::to_value(unavailable).unwrap();
        assert_eq!(json["status"], "unsupported");
        assert!(json["usageBytes"].is_null());
        assert!(json["budgetBytes"].is_null());
        let mut available = MemoryReport::new("test", "processHeap", "heap");
        available.usage_bytes = Some(0);
        available.budget_bytes = Some(0);
        let json = serde_json::to_value(available).unwrap();
        assert_eq!(json["status"], "available");
        assert_eq!(json["usageBytes"], 0);
        assert_eq!(json["budgetBytes"], 0);
    }
    #[test]
    fn recommendations_do_not_become_budgets_or_residency() {
        let mut report = MemoryReport::new("metal.deviceMemory", "processDevice", "device");
        report.usage_bytes = Some(200);
        report.recommended_max_working_set_bytes = Some(100);
        let json = serde_json::to_value(report).unwrap();
        assert_eq!(json["usageBytes"], 200);
        assert_eq!(json["recommendedMaxWorkingSetBytes"], 100);
        assert!(json["budgetBytes"].is_null());
        assert!(json.get("residentBytes").is_none());
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "requires a Windows DX12 device"]
    fn dx12_memory_reports_query_the_selected_adapter() {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::DX12,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = pollster::block_on(instance.request_adapter(&Default::default())).unwrap();
        assert_eq!(adapter.get_info().backend, wgpu::Backend::Dx12);
        let (device, queue) =
            pollster::block_on(adapter.request_device(&Default::default())).unwrap();
        let buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("memory report qualification"),
            size: 1024 * 1024,
            usage: wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let reports = inspect(&device);
        assert!(!reports.is_empty());
        assert_eq!(reports.len() % 2, 0);
        for pair in reports.chunks_exact(2) {
            assert_eq!(pair[0].region, "local");
            assert_eq!(pair[1].region, "nonLocal");
            assert_eq!(pair[0].node_index, pair[1].node_index);
            for report in pair {
                assert_eq!(report.status, "available", "{report:?}");
                assert_eq!(report.source, "dxgi.QueryVideoMemoryInfo");
                assert_eq!(report.scope, "processAdapterSegment");
                assert!(report.usage_bytes.is_some());
                assert!(report.budget_bytes.is_some());
                assert!(report.recommended_max_working_set_bytes.is_none());
            }
        }
        println!("GPU_MEMORY {}", serde_json::to_string(&reports).unwrap());
        drop(buffer);
        drop(queue);
        drop(device);
    }
}
