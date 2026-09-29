use crate::resources::{
    ResourceError,
    registry::{ResourceKey, ResourceRegistry, next_registry_id},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Arc, Weak},
};

pub const MAX_COMMAND_BYTES: usize = 8 * 1024 * 1024;
pub const RESPONSE_CAPACITY: usize = 256 * 1024;
const MAX_SOURCE_BYTES: usize = 1024 * 1024;
const MAX_PROGRAMS: u64 = 256;
const SOURCE_BUDGET: u64 = 16 * 1024 * 1024;

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
    Compile { source: String, label: String },
    Retain { key: [u64; 4] },
    Release { key: [u64; 4] },
    Stats {},
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EntryPoint {
    pub name: String,
    pub stage: &'static str,
    pub workgroup_size: Option<[u32; 3]>,
}
#[derive(Clone, Serialize)]
pub struct Diagnostic {
    pub message: String,
    pub severity: &'static str,
    pub location: Option<Location>,
}
#[derive(Clone, Serialize)]
pub struct Location {
    pub line: usize,
    pub column: usize,
    pub offset: usize,
    pub length: usize,
}
#[derive(Serialize)]
pub struct ShaderError {
    pub code: &'static str,
    pub diagnostics: Vec<Diagnostic>,
}
impl ShaderError {
    fn new(code: &'static str, message: &str) -> Self {
        Self {
            code,
            diagnostics: vec![Diagnostic {
                message: bounded_text(message),
                severity: "error",
                location: None,
            }],
        }
    }
}
impl From<ResourceError> for ShaderError {
    fn from(error: ResourceError) -> Self {
        Self::new(
            match error {
                ResourceError::StaleKey => "staleProgram",
                ResourceError::BudgetExceeded => "limitExceeded",
                _ => "invalidCommand",
            },
            &error.to_string(),
        )
    }
}

pub struct CompiledShader {
    pub module: wgpu::ShaderModule,
    pub entry_points: Vec<EntryPoint>,
    pub diagnostics: Vec<Diagnostic>,
}

pub struct ShaderStore {
    registry: ResourceRegistry<Arc<CompiledShader>>,
    cache: HashMap<Arc<str>, Weak<CompiledShader>>,
    compilation_count: u64,
    cache_hits: u64,
}
impl Default for ShaderStore {
    fn default() -> Self {
        Self {
            registry: ResourceRegistry::new(next_registry_id(), 1, SOURCE_BUDGET),
            cache: HashMap::new(),
            compilation_count: 0,
            cache_hits: 0,
        }
    }
}

fn bounded_text(value: &str) -> String {
    let end = value.floor_char_boundary(value.len().min(4096));
    value[..end].to_owned()
}
fn location(source: &str, span: wgpu::SourceLocation) -> Option<Location> {
    let start = span.offset as usize;
    let end = start.checked_add(span.length as usize)?;
    let prefix = source.get(..start)?;
    let text = source.get(start..end)?;
    Some(Location {
        line: prefix.bytes().filter(|b| *b == b'\n').count() + 1,
        column: prefix.rsplit('\n').next()?.encode_utf16().count() + 1,
        offset: prefix.encode_utf16().count(),
        length: text.encode_utf16().count(),
    })
}
fn diagnostics(source: &str, info: wgpu::CompilationInfo) -> Vec<Diagnostic> {
    info.messages
        .into_iter()
        .take(8)
        .map(|message| Diagnostic {
            message: bounded_text(&message.message),
            severity: match message.message_type {
                wgpu::CompilationMessageType::Error => "error",
                wgpu::CompilationMessageType::Warning => "warning",
                wgpu::CompilationMessageType::Info => "info",
            },
            location: message.location.and_then(|span| location(source, span)),
        })
        .collect()
}
fn key(value: [u64; 4]) -> ResourceKey {
    ResourceKey {
        renderer: value[0],
        device_generation: value[1],
        slot: value[2],
        slot_generation: value[3],
    }
}
fn key_value(key: ResourceKey) -> [u64; 4] {
    [
        key.renderer,
        key.device_generation,
        key.slot,
        key.slot_generation,
    ]
}

impl ShaderStore {
    pub(crate) fn retain_graph(&mut self, keys: &[ResourceKey]) -> Result<(), ResourceError> {
        for (index, key) in keys.iter().enumerate() {
            if let Err(error) = self.registry.retain(*key) {
                for previous in &keys[..index] {
                    let _ = self.registry.release(*previous);
                }
                return Err(error);
            }
        }
        Ok(())
    }
    pub(crate) fn release_graph(&mut self, keys: &[ResourceKey]) -> Result<(), ResourceError> {
        for key in keys {
            self.registry.release(*key)?;
        }
        self.registry.retire_completed(0);
        self.cache.retain(|_, module| module.strong_count() > 0);
        Ok(())
    }
    pub fn resolve(&self, key: ResourceKey) -> Result<&CompiledShader, ResourceError> {
        self.registry.resolve(key).map(Arc::as_ref)
    }

    fn compile(
        &mut self,
        device: &wgpu::Device,
        source: String,
        label: String,
    ) -> Result<Value, ShaderError> {
        if source.len() > MAX_SOURCE_BYTES
            || label.len() > 1024
            || self.registry.live_allocations() >= MAX_PROGRAMS
        {
            return Err(ShaderError::new(
                "limitExceeded",
                "Shader source, label or live program limit exceeded",
            ));
        }
        if source.trim().is_empty() {
            return Err(ShaderError::new(
                "invalidSource",
                "WGSL source must not be empty",
            ));
        }
        self.registry.check_capacity(source.len() as u64)?;
        self.cache.retain(|_, module| module.strong_count() > 0);
        let compiled =
            if let Some(compiled) = self.cache.get(source.as_str()).and_then(Weak::upgrade) {
                self.cache_hits = self.cache_hits.saturating_add(1);
                compiled
            } else {
                self.compilation_count = self.compilation_count.saturating_add(1);
                let parsed =
                    wgpu::naga::front::wgsl::parse_str(&source).map_err(|error| ShaderError {
                        code: "invalidSource",
                        diagnostics: vec![Diagnostic {
                            message: bounded_text(&error.emit_to_string(&source)),
                            severity: "error",
                            location: error
                                .location(&source)
                                .and_then(|span| location(&source, span.into())),
                        }],
                    })?;
                if parsed.entry_points.len() > 64
                    || parsed.entry_points.iter().any(|e| e.name.len() > 512)
                {
                    return Err(ShaderError::new(
                        "limitExceeded",
                        "Shader entry point limit exceeded",
                    ));
                }
                let entry_points = parsed
                    .entry_points
                    .iter()
                    .map(|entry| {
                        let stage = match entry.stage {
                            wgpu::naga::ShaderStage::Vertex => "vertex",
                            wgpu::naga::ShaderStage::Fragment => "fragment",
                            wgpu::naga::ShaderStage::Compute => "compute",
                            _ => {
                                return Err(ShaderError::new(
                                    "unsupportedFeature",
                                    "Shader stage is not supported",
                                ));
                            }
                        };
                        Ok(EntryPoint {
                            name: entry.name.clone(),
                            stage,
                            workgroup_size: (stage == "compute"
                                && entry.workgroup_size_overrides.is_none())
                            .then_some(entry.workgroup_size),
                        })
                    })
                    .collect::<Result<Vec<_>, _>>()?;
                let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
                let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
                let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
                let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                    label: Some(&label),
                    source: wgpu::ShaderSource::Wgsl(source.as_str().into()),
                });
                let info = pollster::block_on(module.get_compilation_info());
                let internal_error = pollster::block_on(internal.pop());
                let memory_error = pollster::block_on(memory.pop());
                let validation_error = pollster::block_on(validation.pop());
                if let Some(error) = internal_error.or(memory_error) {
                    return Err(ShaderError::new("deviceFailed", &error.to_string()));
                }
                let mut diagnostics = diagnostics(&source, info);
                if let Some(error) = validation_error
                    && !diagnostics.iter().any(|d| d.severity == "error")
                {
                    diagnostics.truncate(7);
                    diagnostics.push(Diagnostic {
                        message: bounded_text(&error.to_string()),
                        severity: "error",
                        location: None,
                    });
                }
                if diagnostics.iter().any(|d| d.severity == "error") {
                    return Err(ShaderError {
                        code: "invalidSource",
                        diagnostics,
                    });
                }
                let compiled = Arc::new(CompiledShader {
                    module,
                    entry_points,
                    diagnostics,
                });
                self.cache
                    .insert(Arc::from(source.as_str()), Arc::downgrade(&compiled));
                compiled
            };
        let key = self
            .registry
            .insert(compiled.clone(), source.len() as u64)?;
        Ok(
            json!({"key": key_value(key), "entryPoints": compiled.entry_points, "diagnostics": compiled.diagnostics}),
        )
    }

    pub fn execute(
        &mut self,
        device: &wgpu::Device,
        bytes: &[u8],
        capacity: usize,
        failure: &mut Option<String>,
    ) -> Result<Vec<u8>, String> {
        // Reserve the full bounded response before any mutation, including retain.
        if bytes.len() > MAX_COMMAND_BYTES || capacity != RESPONSE_CAPACITY {
            return Err("Invalid shader command buffer size".into());
        }
        let request: Request =
            serde_json::from_slice(bytes).map_err(|_| "Invalid shader command")?;
        if request.version != 1 || request.request > i64::MAX as u64 {
            return Err("Unsupported shader command version or request ID".into());
        }
        let result: Result<Value, ShaderError> = if failure.is_some() {
            Err(ShaderError::new(
                "deviceFailed",
                "Recreate the failed native device",
            ))
        } else {
            match request.command {
                Command::Compile { source, label } => self.compile(device, source, label),
                Command::Retain { key: value } => self
                    .registry
                    .retain(key(value))
                    .map(|()| json!({}))
                    .map_err(Into::into),
                Command::Release { key: value } => {
                    let result = self.registry.release(key(value));
                    self.registry.retire_completed(0);
                    self.cache.retain(|_, module| module.strong_count() > 0);
                    result.map(|()| json!({})).map_err(Into::into)
                }
                Command::Stats {} => Ok(json!({
                    "residentSourceBytes": self.registry.resident_bytes(),
                    "livePrograms": self.registry.live_allocations(),
                    "cachedModules": self.cache.len(),
                    "compilationCount": self.compilation_count,
                    "cacheHits": self.cache_hits,
                })),
            }
        };
        let response = match result {
            Ok(value) => json!({"version": 1, "request": request.request, "result": value}),
            Err(error) => {
                if error.code == "deviceFailed" {
                    *failure = Some("Native shader device failed; recreate this renderer".into());
                }
                json!({"version": 1, "request": request.request, "error": error})
            }
        };
        let bytes = serde_json::to_vec(&response).map_err(|e| e.to_string())?;
        // Limits above bound escaped diagnostics and entry point names below this.
        assert!(bytes.len() <= RESPONSE_CAPACITY);
        Ok(bytes)
    }
}
