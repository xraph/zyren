mod bindings;
mod compile;
pub(crate) mod descriptor;
mod execute;
mod frame;
mod materials;
mod mesh;
pub(crate) use frame::{FrameGraph, decode_packet as decode_frame_packet};
pub(crate) use mesh::PreparedMaterial;

use crate::{
    resources::{
        ResourceError, ResourceStore,
        registry::{ResourceKey, ResourceRegistry, next_registry_id},
    },
    shaders::ShaderStore,
};
use descriptor::{Description, Key};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Arc, Weak},
};

pub const MAX_COMMAND_BYTES: usize = 8 * 1024 * 1024;
pub const RESPONSE_CAPACITY: usize = 256 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    version: u32,
    request: u64,
    command: Command,
}
#[derive(Deserialize)]
#[serde(tag = "operation", rename_all = "camelCase", deny_unknown_fields)]
enum Command {
    CompileMaterial { description: Description },
    ReleaseMaterial { key: Key },
    RetainMaterial { key: Key },
    Compile { description: Description },
    CompileMesh { description: mesh::Description },
    ReleaseMesh { key: Key },
    Execute { key: Key },
    Release { key: Key },
    Stats {},
    DeviceInfo {},
    FrameProfile {},
    InspectGpu { allocation_limit: usize },
    ShadowStats {},
    TemporalStats {},
    TransmissionStats {},
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GraphError {
    code: &'static str,
    message: String,
    pass_name: Option<String>,
    resource_label: Option<String>,
}
impl GraphError {
    pub(crate) fn is_device_failure(&self) -> bool {
        self.code == "deviceFailed"
    }
    fn new(code: &'static str, message: &str) -> Self {
        Self {
            code,
            message: message[..message.floor_char_boundary(message.len().min(4096))].into(),
            pass_name: None,
            resource_label: None,
        }
    }
    fn at(mut self, name: &str) -> Self {
        self.pass_name = Some(name[..name.floor_char_boundary(name.len().min(1024))].into());
        self
    }
}
impl std::fmt::Display for GraphError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "graph.{}: {}", self.code, self.message)
    }
}
impl From<ResourceError> for GraphError {
    fn from(error: ResourceError) -> Self {
        Self::new(
            match error {
                ResourceError::StaleKey => "closedResource",
                ResourceError::BudgetExceeded => "limitExceeded",
                ResourceError::DeviceFailed => "deviceFailed",
                _ => "invalidBinding",
            },
            &error.to_string(),
        )
    }
}
fn key(value: Key) -> ResourceKey {
    ResourceKey {
        renderer: value[0],
        device_generation: value[1],
        slot: value[2],
        slot_generation: value[3],
    }
}
fn key_value(key: ResourceKey) -> Key {
    [
        key.renderer,
        key.device_generation,
        key.slot,
        key.slot_generation,
    ]
}

#[derive(Hash, PartialEq, Eq)]
struct PipelineKey {
    module: wgpu::ShaderModule,
    bindings: Vec<bindings::LayoutKey>,
    compute: String,
    vertex: String,
    fragment: String,
    format: Option<wgpu::TextureFormat>,
    blend: descriptor::Blend,
}
enum PipelineKind {
    Compute(wgpu::ComputePipeline),
    Render(wgpu::RenderPipeline),
}
struct Pipeline {
    kind: PipelineKind,
    layouts: Vec<wgpu::BindGroupLayout>,
}
struct PreparedPass {
    name: String,
    pipeline: Arc<Pipeline>,
    groups: Vec<wgpu::BindGroup>,
    color: Option<(wgpu::TextureView, wgpu::Operations<wgpu::Color>)>,
    workgroups: [u32; 3],
    vertex_count: u32,
    instance_count: u32,
}
struct ScopedGraph {
    scene_pass_index: usize,
    passes: Vec<PreparedPass>,
    resources: Vec<ResourceKey>,
    shaders: Vec<ResourceKey>,
    frame: Option<(wgpu::Texture, wgpu::Texture)>,
    scene_resource: Option<ResourceKey>,
}
pub struct GraphStore {
    pub(crate) materials: materials::MaterialStore,
    pub(crate) meshes: mesh::MeshStore,
    registry: ResourceRegistry<Arc<ScopedGraph>>,
    cache: HashMap<PipelineKey, Weak<Pipeline>>,
    compilation_count: u64,
    cache_hits: u64,
}
impl Default for GraphStore {
    fn default() -> Self {
        Self {
            meshes: mesh::MeshStore::default(),
            materials: materials::MaterialStore::default(),
            registry: ResourceRegistry::new(next_registry_id(), 1, 16 * 1024 * 1024),
            cache: HashMap::new(),
            compilation_count: 0,
            cache_hits: 0,
        }
    }
}

fn scoped<T>(
    device: &wgpu::Device,
    label: &str,
    work: impl FnOnce() -> Result<T, GraphError>,
) -> Result<T, GraphError> {
    let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
    let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
    let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
    let result = work();
    let internal = pollster::block_on(internal.pop());
    let memory = pollster::block_on(memory.pop());
    let validation = pollster::block_on(validation.pop());
    if let Some(error) = internal.or(memory) {
        return Err(GraphError::new("deviceFailed", &error.to_string()).at(label));
    }
    if let Some(error) = validation {
        return Err(GraphError::new("pipelineFailed", &error.to_string()).at(label));
    }
    result.map_err(|error| error.at(label))
}

pub(crate) struct GraphContext<'a> {
    pub temporal_stats: (u64, usize),
    pub transmission_bytes: u64,
    pub shadow_stats: crate::renderer::ShadowStats,
    pub mesh_layout: &'a wgpu::BindGroupLayout,
    pub deformation_layout: &'a wgpu::BindGroupLayout,
    pub device: &'a wgpu::Device,
    pub queue: &'a wgpu::Queue,
    pub resources: &'a mut ResourceStore,
    pub shaders: &'a mut ShaderStore,
    pub failure: &'a mut Option<String>,
    pub engine_layout: &'a wgpu::BindGroupLayout,
    pub target_bytes: u64,
    pub shadow_bytes: u64,
    pub shadow_passes: u64,
    pub instance_bytes: u64,
    pub instance_uploaded_bytes: u64,
    pub instance_draw_calls: usize,
    pub device_info: Value,
    pub last_gpu_time_ns: Option<u64>,
    pub diagnostic_readback_bytes: u64,
    pub gpu_time_source: &'static str,
    pub submitted_frames: u64,
    pub frame_profile: Value,
}

impl GraphStore {
    pub(crate) fn command(
        &mut self,
        context: GraphContext<'_>,
        bytes: &[u8],
        capacity: usize,
    ) -> Result<Vec<u8>, String> {
        let GraphContext {
            shadow_stats,
            temporal_stats,
            transmission_bytes,
            mesh_layout,
            deformation_layout,
            device,
            queue,
            resources,
            shaders,
            failure,
            engine_layout,
            target_bytes,
            shadow_bytes,
            shadow_passes,
            instance_bytes,
            instance_uploaded_bytes,
            instance_draw_calls,
            device_info,
            last_gpu_time_ns,
            gpu_time_source,
            diagnostic_readback_bytes,
            submitted_frames,
            frame_profile,
        } = context;
        if bytes.len() > MAX_COMMAND_BYTES || capacity != RESPONSE_CAPACITY {
            return Err("Invalid graph command capacity".into());
        }
        let request: Request =
            serde_json::from_slice(bytes).map_err(|_| "Invalid graph command")?;
        if request.version != 1 || request.request > i64::MAX as u64 {
            return Err("Unsupported graph protocol version or request ID".into());
        }
        let result: Result<Value, GraphError> = if failure.is_some() {
            Err(GraphError::new(
                "deviceFailed",
                "Recreate the failed native device",
            ))
        } else {
            match request.command {
                Command::CompileMesh { description } => self
                    .meshes
                    .compile(
                        &mut GraphContext {
                            shadow_stats,
                            temporal_stats,
                            transmission_bytes,
                            device,
                            queue,
                            resources,
                            shaders,
                            failure,
                            mesh_layout,
                            deformation_layout,
                            engine_layout,
                            target_bytes,
                            shadow_bytes,
                            shadow_passes,
                            instance_bytes,
                            instance_uploaded_bytes,
                            instance_draw_calls,
                            device_info,
                            last_gpu_time_ns,
                            gpu_time_source,
                            diagnostic_readback_bytes,
                            submitted_frames,
                            frame_profile,
                        },
                        description,
                        bytes.len() as u64,
                    )
                    .map(|key| json!({"key": key})),
                Command::ReleaseMesh { key: value } => self
                    .meshes
                    .release(device, resources, shaders, key(value))
                    .map(|()| json!({})),
                Command::Compile { description } => self
                    .compile(device, resources, shaders, description, bytes.len() as u64)
                    .map(|key| json!({"key": key})),
                Command::Execute { key: value } => {
                    self.execute(device, queue, resources, key(value))
                }
                Command::Release { key: value } => self
                    .release(device, resources, shaders, key(value))
                    .map(|()| json!({})),
                Command::TransmissionStats {} => {
                    Ok(json!({"residentBytes":transmission_bytes,"fixedBytes":8}))
                }
                Command::TemporalStats {} => Ok(json!({
                    "residentBytes": temporal_stats.0, "historyViews": temporal_stats.1,
                })),
                Command::ShadowStats {} => Ok(json!({
                    "atlasCount": shadow_stats.atlas_count, "residentBytes": shadow_stats.resident_bytes,
                    "renderedViews": shadow_stats.rendered_views, "reusedFrames": shadow_stats.reused_frames,
                })),
                Command::InspectGpu { allocation_limit } => {
                    if !(1..=256).contains(&allocation_limit) {
                        Err(GraphError::new(
                            "limitExceeded",
                            "Allocation limit must be between 1 and 256",
                        ))
                    } else {
                        let mut result = resources.inspection(allocation_limit);
                        result["memoryReports"] =
                            json!(crate::renderer::gpu_memory::inspect(device));
                        #[cfg(target_vendor = "apple")]
                        let allocated = {
                            use objc2_metal::MTLDevice;
                            // SAFETY: query only, with no device mutation or escaping HAL borrow.
                            unsafe { device.as_hal::<wgpu::hal::api::Metal>() }
                                .map(|hal| hal.raw_device().currentAllocatedSize() as u64)
                        };
                        #[cfg(not(target_vendor = "apple"))]
                        let allocated: Option<u64> = None;
                        let report = device.generate_allocator_report();
                        result["allocatorSource"] = json!(if report.is_some() {
                            "wgpu.suballocator"
                        } else {
                            "unavailable"
                        });
                        result["allocatorUsedBytes"] =
                            json!(report.as_ref().map(|report| report.total_allocated_bytes));
                        result["allocatorReservedBytes"] =
                            json!(report.as_ref().map(|report| report.total_reserved_bytes));
                        result["allocatorAllocationCount"] =
                            json!(report.as_ref().map(|report| report.allocations.len()));
                        result["allocatorAllocations"] = json!(report.as_ref().map(|report| report.allocations.iter().take(allocation_limit).map(|allocation| json!({
                            "name": &allocation.name[..allocation.name.floor_char_boundary(allocation.name.len().min(128))],
                            "offset": allocation.offset, "size": allocation.size
                        })).collect::<Vec<_>>()).unwrap_or_default());
                        result["diagnosticReadbackBytes"] = json!(diagnostic_readback_bytes);
                        result["lastSubmissionGpuTimeNs"] = json!(last_gpu_time_ns);
                        result["frameProfile"] = frame_profile;
                        result["submittedFrames"] = json!(submitted_frames);
                        result["gpuTimeSource"] = json!(gpu_time_source);
                        result["deviceAllocatedBytes"] = json!(allocated);
                        result["deviceAllocationSource"] = json!(if allocated.is_some() {
                            "metal.currentAllocatedSize"
                        } else {
                            "unavailable"
                        });
                        Ok(result)
                    }
                }
                Command::FrameProfile {} => Ok(frame_profile),
                Command::DeviceInfo {} => Ok(device_info),
                Command::CompileMaterial { description } => self
                    .materials
                    .compile(
                        device,
                        resources,
                        shaders,
                        engine_layout,
                        description,
                        bytes.len() as u64,
                    )
                    .map(|key| json!({"key": key})),
                Command::RetainMaterial { key } => self.materials.retain(key).map(|()| json!({})),
                Command::ReleaseMaterial { key } => self
                    .materials
                    .release(device, resources, shaders, key)
                    .map(|()| json!({})),
                Command::Stats {} => Ok(
                    json!({"liveGraphs": self.registry.live_allocations(), "descriptionBytes": self.registry.resident_bytes(),
                "cachedPipelines": self.cache.len(), "pipelineCompilations": self.compilation_count, "cacheHits": self.cache_hits,
                "targetBytes":target_bytes,"shadowBytes":shadow_bytes,"shadowPasses":shadow_passes,
                "instanceBytes":instance_bytes,"instanceUploadedBytes":instance_uploaded_bytes,"instanceDrawCalls":instance_draw_calls,"liveMaterials":self.materials.live(),
                "liveMeshShaders": self.meshes.count(), "meshPipelines": self.meshes.pipelines()}),
                ),
            }
        };
        self.cache.retain(|_, pipeline| pipeline.strong_count() > 0);
        let response = match result {
            Ok(result) => json!({"version": 1, "request": request.request, "result": result}),
            Err(error) => {
                if error.code == "deviceFailed" {
                    *failure = Some("Graph device failed; recreate this renderer".into());
                }
                json!({"version": 1, "request": request.request, "error": error})
            }
        };
        let bytes = serde_json::to_vec(&response).map_err(|e| e.to_string())?;
        assert!(bytes.len() <= RESPONSE_CAPACITY);
        Ok(bytes)
    }
    fn release(
        &mut self,
        device: &wgpu::Device,
        resources: &mut ResourceStore,
        shaders: &mut ShaderStore,
        key: ResourceKey,
    ) -> Result<(), GraphError> {
        let graph = self.registry.resolve(key)?.clone();
        self.registry.release(key)?;
        self.registry.retire_completed(0);
        resources.release_graph(device, &graph.resources)?;
        shaders.release_graph(&graph.shaders)?;
        drop(graph);
        self.cache.retain(|_, pipeline| pipeline.strong_count() > 0);
        Ok(())
    }
}
