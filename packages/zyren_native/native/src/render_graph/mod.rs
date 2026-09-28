mod bindings;
mod compile;
mod descriptor;
mod execute;
pub(crate) mod materials;

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
    Execute { key: Key },
    Release { key: Key },
    Stats {},
    DeviceInfo {},
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
    passes: Vec<PreparedPass>,
    resources: Vec<ResourceKey>,
    shaders: Vec<ResourceKey>,
}
pub struct GraphStore {
    pub(crate) materials: materials::MaterialStore,
    registry: ResourceRegistry<Arc<ScopedGraph>>,
    cache: HashMap<PipelineKey, Weak<Pipeline>>,
    compilation_count: u64,
    cache_hits: u64,
}
impl Default for GraphStore {
    fn default() -> Self {
        Self {
            materials: Default::default(),
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
}

impl GraphStore {
    pub(crate) fn command(
        &mut self,
        context: GraphContext<'_>,
        bytes: &[u8],
        capacity: usize,
    ) -> Result<Vec<u8>, String> {
        let GraphContext {
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
                    .map(|key| json!({"key":key})),
                Command::ReleaseMaterial { key } => self
                    .materials
                    .release(device, resources, shaders, key)
                    .map(|()| json!({})),
                Command::RetainMaterial { key } => self.materials.retain(key).map(|()| json!({})),
                Command::Compile { description } => self
                    .compile(device, resources, shaders, description, bytes.len() as u64)
                    .map(|key| json!({"key": key})),
                Command::Execute { key: value } => {
                    self.execute(device, queue, resources, key(value))
                }
                Command::Release { key: value } => self
                    .release(device, resources, shaders, key(value))
                    .map(|()| json!({})),
                Command::DeviceInfo {} => Ok(device_info),
                Command::Stats {} => Ok(
                    json!({"instanceBytes":instance_bytes,"instanceUploadedBytes":instance_uploaded_bytes,"instanceDrawCalls":instance_draw_calls,"shadowBytes":shadow_bytes,"shadowPasses":shadow_passes,"targetBytes": target_bytes, "liveMaterials": self.materials.live(), "liveGraphs": self.registry.live_allocations(), "descriptionBytes": self.registry.resident_bytes(),
                "cachedPipelines": self.cache.len(), "pipelineCompilations": self.compilation_count, "cacheHits": self.cache_hits}),
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
