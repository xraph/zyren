mod admission;
mod area_lights;
mod energy_lut;
mod environment;
mod scene_capture;
mod sensor_capture;
use std::{
    collections::{HashMap, HashSet},
    sync::mpsc,
    time::Duration,
};

use bytemuck::{Pod, Zeroable};
use glam::Mat4;
use wgpu::util::DeviceExt;

use crate::scene::{Frame, pixel_len};
mod batching;
mod composition;
mod deformation;
mod draw_cache;
mod draw_order;
pub(crate) mod effects;
pub(crate) mod gpu_memory;
mod instances;
mod materials;
mod multisample;
mod outlines;
mod physical_maps;
mod pipelines;
pub(crate) mod scene_inputs;
pub(crate) mod screen_lighting;
mod shadows;
mod temporal;
mod textures;
mod timing;
mod transmission;
pub use shadows::ShadowStats;

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct Uniforms {
    mvp: [f32; 16],
    normal_matrix: [f32; 16],
    color_unlit: [f32; 4],
    light_ambient: [f32; 4],
    map_params: [f32; 4],
    view_projection: [f32; 16],
    model: [f32; 16],
    primitive: [f32; 4],
    viewport: [f32; 4],
    pbr_params: [f32; 4],
    emissive: [f32; 4],
    pbr_maps: [u32; 4],
    pbr_factors: [f32; 4],
    physical: [[f32; 4]; 4],
    transmission: [[f32; 4]; 2],
    optical: [[f32; 4]; 2],
    capture_projection: [f32; 16],
    clipping_planes: [[f32; 4]; 6],
    clipping: [f32; 4],
    inverse_view_projection: [f32; 16],
}

struct GpuGeometry {
    deformation_bounds: crate::deformation::SourceBounds,
    key: crate::resources::registry::ResourceKey,
    recipe: std::sync::Arc<crate::scene::Geometry>,
    center: glam::Vec3,
    bounds: batching::Bounds,
}
struct Targets {
    width: u32,
    height: u32,
    stride: u32,
    color: wgpu::Texture,
    color_view: wgpu::TextureView,
    _depth: wgpu::Texture,
    depth_view: wgpu::TextureView,
    readback: wgpu::Buffer,
    sensor_depth: Option<wgpu::Buffer>,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct RenderCounters {
    pub submitted_frames: u64,
    pub readback_bytes: u64,
}
struct DepthTarget {
    width: u32,
    height: u32,
    _texture: wgpu::Texture,
    view: wgpu::TextureView,
}

struct Submission {
    index: wgpu::SubmissionIndex,
    timing: Option<timing::Pending>,
    #[cfg(target_vendor = "apple")]
    metal: Option<crate::interop::metal::MetalCompletion>,
}

pub struct Renderer {
    state: Option<Box<RendererState>>,
}

// Fields remain private; dereferencing keeps the renderer implementation local
// while allowing its complete GPU ownership to move during retirement.
#[doc(hidden)]
pub struct RendererState {
    pub(crate) device: wgpu::Device,
    pub(crate) queue: wgpu::Queue,
    #[cfg(target_os = "android")]
    pub(crate) instance: wgpu::Instance,
    #[cfg(target_os = "android")]
    pub(crate) adapter: wgpu::Adapter,
    #[cfg(target_os = "android")]
    pub(crate) android: Option<crate::interop::android::AndroidTarget>,
    #[cfg(target_os = "android")]
    pub(crate) android_generation: u64,
    pipelines: pipelines::MeshPipelines,
    compositor: composition::Compositor,
    effects: effects::Effects,
    supports_msaa4: bool,
    outlines: outlines::Outlines,
    outline_materials: Vec<Option<crate::render_graph::PreparedMaterial>>,
    effect_resources: Vec<crate::resources::registry::ResourceKey>,
    instance_uploaded_bytes: u64,
    texture_layout: wgpu::BindGroupLayout,
    standard_texture_layout: wgpu::BindGroupLayout,
    textures: HashMap<u32, textures::GpuSceneTexture>,
    surface_depth: Option<DepthTarget>,
    failed_surface: Option<wgpu::Texture>,
    failed_surface_depth: Option<wgpu::Texture>,
    #[cfg(target_vendor = "apple")]
    pub(crate) drawable_owner: Option<crate::interop::metal::DrawableOwner>,
    pub(crate) failure: Option<String>,
    capture_views: HashSet<u64>,
    next_capture_view: u64,
    retirement_tickets: HashMap<u64, crate::resources::registry::ResourceKey>,
    next_retirement_ticket: u64,
    counters: RenderCounters,
    last_scene_draws: std::cell::Cell<u64>,
    last_instance_draws: std::cell::Cell<u64>,
    last_gpu_time_ns: Option<u64>,
    diagnostic_readback_bytes: u64,
    gpu_time_source: &'static str,
    gpu_timer: Option<timing::Timer>,
    profile: std::cell::RefCell<timing::Profile>,
    draw_cache: std::cell::RefCell<draw_cache::Cache>,
    batches: batching::Batches,
    layout: wgpu::BindGroupLayout,
    pbr_layout: wgpu::BindGroupLayout,
    environment_defaults: environment::Defaults,
    energy_lut: energy_lut::System,
    area_tables: area_lights::Tables,
    shadows: shadows::ShadowSystem,
    geometries: HashMap<u32, GpuGeometry>,
    instances: HashMap<u32, instances::GpuInstances>,
    poses: HashMap<u32, deformation::GpuPose>,
    deformation_layout: wgpu::BindGroupLayout,
    resources: crate::resources::ResourceStore,
    shaders: crate::shaders::ShaderStore,
    graphs: crate::render_graph::GraphStore,
    views: HashMap<u64, crate::scene_packet::ViewState>,
    staging: HashMap<u64, crate::scene_packet::ViewState>,
    cover_bindings: HashMap<u64, admission::CoverBindings>,
    targets: Option<Targets>,
    sensor_depth_capture: bool,
    temporal: temporal::System,
    transmission: transmission::System,
    screen_lighting: screen_lighting::System,
    pub adapter_name: String,
    pub backend: wgpu::Backend,
    _permit: crate::retirement::DevicePermit,
}
#[cfg(target_os = "android")]
impl Drop for RendererState {
    fn drop(&mut self) {
        // Failed sessions reach this on the bounded retirement worker. Keep the
        // acquired image, swapchain and native window alive until GPU idle/loss.
        let _ = self.device.poll(wgpu::PollType::Wait {
            submission_index: None,
            timeout: None,
        });
    }
}
impl std::ops::Deref for Renderer {
    type Target = RendererState;
    fn deref(&self) -> &Self::Target {
        self.state.as_deref().expect("renderer owns its state")
    }
}
impl std::ops::DerefMut for Renderer {
    fn deref_mut(&mut self) -> &mut Self::Target {
        self.state.as_deref_mut().expect("renderer owns its state")
    }
}
impl Drop for Renderer {
    fn drop(&mut self) {
        if let Some(mut state) = self.state.take() {
            if state.failure.is_none() && state.resources.shutdown(&state.device).is_err() {
                state.failure = Some("GPU shutdown completion failed".into());
            }
            if state.failure.is_some() {
                crate::retirement::retire(state);
            } else {
                drop(state);
            }
        }
    }
}

impl Renderer {
    pub async fn new() -> Result<Self, String> {
        let permit = crate::retirement::reserve_device()?;
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::METAL | wgpu::Backends::VULKAN | wgpu::Backends::DX12,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::HighPerformance,
                compatible_surface: None,
                force_fallback_adapter: false,
                ..Default::default()
            })
            .await
            .map_err(|e| format!("no Metal, Vulkan or DX12 adapter: {e}"))?;
        let supports_msaa4 = [
            wgpu::TextureFormat::Rgba16Float,
            wgpu::TextureFormat::Depth32Float,
            outlines::FORMAT,
        ]
        .iter()
        .all(|format| {
            adapter
                .get_texture_format_features(*format)
                .flags
                .contains(wgpu::TextureFormatFeatureFlags::MULTISAMPLE_X4)
        });
        let info = adapter.get_info();
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("flutter_zyren"),
                required_features: (adapter.features()
                    & (wgpu::Features::TEXTURE_COMPRESSION_BC
                        | wgpu::Features::TEXTURE_COMPRESSION_ETC2
                        | wgpu::Features::TEXTURE_COMPRESSION_ASTC))
                    | timing::features(adapter.features(), info.backend),
                required_limits: wgpu::Limits {
                    max_texture_dimension_2d: crate::scene::MAX_DIMENSION,
                    max_sampled_textures_per_shader_stage: adapter
                        .limits()
                        .max_sampled_textures_per_shader_stage
                        .min(32),
                    ..wgpu::Limits::downlevel_defaults()
                },
                ..Default::default()
            })
            .await
            .map_err(|e| format!("device creation failed: {e}"))?;
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(std::mem::size_of::<Uniforms>() as u64),
                },
                count: None,
            }],
        });
        let pbr_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("standard material frame"),
            entries: &[
                vec![
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Uniform,
                            has_dynamic_offset: false,
                            min_binding_size: wgpu::BufferSize::new(
                                std::mem::size_of::<Uniforms>() as u64,
                            ),
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Buffer {
                            ty: wgpu::BufferBindingType::Uniform,
                            has_dynamic_offset: false,
                            min_binding_size: wgpu::BufferSize::new(std::mem::size_of::<
                                crate::lighting::LightingUniform,
                            >()
                                as u64),
                        },
                        count: None,
                    },
                ],
                environment::layout_entries(),
                shadows::layout_entries(),
                area_lights::layout_entries(),
                transmission::layout_entries(),
                screen_lighting::layout_entries(),
            ]
            .concat(),
        });
        let environment_defaults = environment::Defaults::new(&device);
        let area_tables = area_lights::Tables::new(&device, &queue);
        let transmission = transmission::System::new(&device);
        let screen_lighting = screen_lighting::System::new(&device);
        let texture_layout = textures::layout(&device, 1);
        let standard_texture_layout = textures::layout(&device, 5);
        let deformation_layout = deformation::layout(&device);
        let shadows = shadows::ShadowSystem::new(&device, &texture_layout, &deformation_layout);
        let pipelines = pipelines::MeshPipelines::new(
            &device,
            &layout,
            &pbr_layout,
            &texture_layout,
            &standard_texture_layout,
            &deformation_layout,
        );
        Ok(Self {
            state: Some(Box::new(RendererState {
                gpu_timer: timing::Timer::new(&device, &queue),
                device,
                queue,
                #[cfg(target_os = "android")]
                instance,
                #[cfg(target_os = "android")]
                adapter,
                #[cfg(target_os = "android")]
                android: None,
                #[cfg(target_os = "android")]
                android_generation: 0,
                pipelines,
                compositor: composition::Compositor::default(),
                effects: effects::Effects::default(),
                supports_msaa4,
                outlines: outlines::Outlines::default(),
                outline_materials: vec![],
                effect_resources: vec![],
                instance_uploaded_bytes: 0,
                texture_layout,
                standard_texture_layout,
                pbr_layout,
                environment_defaults,
                energy_lut: Default::default(),
                area_tables,
                shadows,
                textures: HashMap::new(),
                surface_depth: None,
                failed_surface: None,
                failed_surface_depth: None,
                #[cfg(target_vendor = "apple")]
                drawable_owner: None,
                failure: None,
                profile: Default::default(),
                draw_cache: Default::default(),
                batches: Default::default(),
                last_gpu_time_ns: None,
                diagnostic_readback_bytes: 0,
                gpu_time_source: "unavailable",
                capture_views: HashSet::new(),
                next_capture_view: 1 << 52,
                retirement_tickets: HashMap::new(),
                next_retirement_ticket: 0,
                counters: RenderCounters::default(),
                last_scene_draws: std::cell::Cell::new(0),
                last_instance_draws: std::cell::Cell::new(0),
                layout,
                geometries: HashMap::new(),
                instances: HashMap::new(),
                poses: HashMap::new(),
                deformation_layout,
                resources: crate::resources::ResourceStore::default(),
                shaders: crate::shaders::ShaderStore::default(),
                graphs: crate::render_graph::GraphStore::default(),
                views: HashMap::new(),
                staging: HashMap::new(),
                cover_bindings: HashMap::new(),
                targets: None,
                sensor_depth_capture: false,
                temporal: temporal::System::default(),
                transmission,
                screen_lighting,
                adapter_name: info.name,
                backend: info.backend,
                _permit: permit,
            })),
        })
    }

    pub fn resource_command(
        &mut self,
        bytes: &[u8],
        capacity: usize,
    ) -> Result<Vec<u8>, crate::resources::ResourceError> {
        use crate::resources::ResourceError;
        if bytes.len() >= 8
            && (100..=105).contains(&u32::from_le_bytes(bytes[4..8].try_into().unwrap()))
        {
            return self.capture_command(bytes, capacity);
        }
        if self.failure.is_some() {
            return Err(ResourceError::DeviceFailed);
        }
        let state = self.state.as_mut().unwrap();
        let validation = state.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = state
            .device
            .push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = state.device.push_error_scope(wgpu::ErrorFilter::Internal);
        let mut result = state
            .resources
            .execute(&state.device, &state.queue, bytes, capacity);
        for scope in [internal, memory, validation] {
            if pollster::block_on(scope.pop()).is_some() {
                result = Err(ResourceError::DeviceFailed);
            }
        }
        if result == Err(ResourceError::DeviceFailed) {
            state.failure = Some("GPU resource command failed; recreate this renderer".into());
        }
        result
    }

    pub fn shader_command(&mut self, bytes: &[u8], capacity: usize) -> Result<Vec<u8>, String> {
        let state = self.state.as_mut().unwrap();
        state
            .shaders
            .execute(&state.device, bytes, capacity, &mut state.failure)
    }

    pub fn graph_command(&mut self, bytes: &[u8], capacity: usize) -> Result<Vec<u8>, String> {
        let shadow_stats = self.shadow_stats();
        let temporal_stats = self.temporal_stats();
        let transmission_bytes = self.transmission.bytes();
        let state = self.state.as_mut().unwrap();
        if state.profile.borrow().status != "unavailable" {
            state
                .draw_cache
                .borrow()
                .snapshot(&mut state.profile.borrow_mut());
        }
        let mut frame_profile = serde_json::to_value(&*state.profile.borrow()).unwrap();
        frame_profile["resources"] = state.resources.telemetry();
        frame_profile["screenLightingBytes"] = state.screen_lighting.bytes().into();
        state.graphs.command(
            crate::render_graph::GraphContext {
                shadow_stats,
                temporal_stats,
                transmission_bytes,
                mesh_layout: &state.layout,
                deformation_layout: &state.deformation_layout,
                device: &state.device,
                queue: &state.queue,
                resources: &mut state.resources,
                shaders: &mut state.shaders,
                failure: &mut state.failure,
                engine_layout: &state.layout,
                target_bytes: state.effects.bytes() + state.outlines.bytes() + state.screen_lighting.bytes(),
                shadow_bytes: shadow_stats.resident_bytes,
                shadow_passes: shadow_stats.rendered_views,
                instance_bytes: state.instances.values().map(|i| i.recipe.byte_length() as u64).sum(),
                instance_uploaded_bytes: state.instance_uploaded_bytes,
                instance_draw_calls: state.last_instance_draws.get() as usize,
                last_gpu_time_ns: state.last_gpu_time_ns,
                gpu_time_source: state.gpu_time_source,
                diagnostic_readback_bytes: state.diagnostic_readback_bytes,
                submitted_frames: state.counters.submitted_frames,
                frame_profile,
                device_info: serde_json::json!({"backend":format!("{:?}",state.backend),"adapterName":state.adapter_name,"sampleCounts":if state.supports_msaa4 {vec![1,4]} else {vec![1]}, "gpuTimestampQueries":state.gpu_timer.is_some(), "gpuTimestampBufferBytes":if state.gpu_timer.is_some() {timing::BUFFER_BYTES * 2} else {0}}),
            },
            bytes,
            capacity,
        )
    }

    fn resize(&mut self, width: u32, height: u32) {
        if self
            .targets
            .as_ref()
            .is_some_and(|t| t.width == width && t.height == height)
        {
            return;
        }
        let size = wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        };
        let color = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("frame color"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8UnormSrgb,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let depth = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("frame depth"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Depth32Float,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let stride = (width * 4).div_ceil(wgpu::COPY_BYTES_PER_ROW_ALIGNMENT)
            * wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
        let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("RGBA readback"),
            size: stride as u64 * height as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        self.targets = Some(Targets {
            width,
            height,
            stride,
            color_view: color.create_view(&Default::default()),
            color,
            depth_view: depth.create_view(&Default::default()),
            _depth: depth,
            readback,
            sensor_depth: None,
        });
    }

    pub fn counters(&self) -> RenderCounters {
        self.counters
    }

    pub fn decode_scene(&self, bytes: &[u8]) -> Result<Frame, String> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        let (bytes, graph, materials, environment) =
            crate::render_graph::decode_frame_packet(bytes)?;
        let mut frame = self.decode_plain_scene(bytes)?;
        frame.graph = graph;
        frame.environment = environment;
        for (index, key) in materials {
            frame
                .meshes
                .get_mut(index as usize)
                .ok_or("Mesh shader index is outside scene")?
                .shader = Some(key);
        }
        for mesh in &mut frame.meshes {
            mesh.environment_slot = 0;
        }
        for (slot, local) in frame.settings.local_environments.iter().enumerate() {
            for index in &local.meshes {
                frame
                    .meshes
                    .get_mut(*index)
                    .ok_or("Local environment mesh index is outside scene")?
                    .environment_slot = slot + 1;
            }
        }
        for mesh in &mut frame.meshes {
            mesh.scene_inputs = if let Some(key) = mesh.shader {
                self.graphs
                    .meshes
                    .scene_inputs(key)
                    .map_err(|e| e.to_string())?
            } else if let Some(key) = mesh.material_shader {
                self.graphs
                    .materials
                    .resolve(key)
                    .map_err(|e| e.to_string())?
                    .scene_input_layout
                    .is_some()
            } else {
                false
            };
        }
        Ok(frame)
    }
    fn decode_plain_scene(&self, bytes: &[u8]) -> Result<Frame, String> {
        if bytes.starts_with(&4_u32.to_le_bytes()) {
            let (admission, display) = crate::scene_packet::Admission::decode(bytes)?;
            if !display.starts_with(&2_u32.to_le_bytes()) {
                return Err("admission display must be a scene packet".into());
            }
            let mut frame = self.decode_plain_scene(display)?;
            if frame.binary.as_ref().unwrap().view != admission.view {
                return Err("admission display view mismatch".into());
            }
            frame.admission = Some(Box::new(admission));
            return Ok(frame);
        }
        if bytes.starts_with(&2_u32.to_le_bytes()) {
            let packet = crate::scene_packet::ScenePacket::decode(bytes)?;
            let previous = self.views.get(&packet.view());
            let mut frame = packet.resolve(previous)?;
            let mut bytes: usize = frame.geometries.iter().map(|g| g.cpu_byte_length()).sum();
            for patch in &frame.geometry_patches {
                let base = self
                    .geometries
                    .get(&patch.base)
                    .ok_or("geometry patch base is not resident")?;
                bytes = bytes
                    .checked_add(base.recipe.cpu_byte_length())
                    .filter(|n| *n <= 64 * 1024 * 1024)
                    .ok_or("geometry patch CPU budget exceeded")?;
                frame.geometries.push(patch.apply(&base.recipe)?);
            }
            bytes += frame
                .instances
                .iter()
                .map(|i| i.transforms.len() * 64)
                .sum::<usize>();
            for patch in &frame.instance_patches {
                let base = self
                    .instances
                    .get(&patch.base)
                    .ok_or("instance patch base is not resident")?;
                if !previous.is_some_and(|v| v.retained_instances.contains(&patch.base)) {
                    return Err("instance patch base is not owned by its view".into());
                }
                bytes += base.recipe.transforms.len() * 64;
                if bytes > 64 * 1024 * 1024 {
                    return Err("instance patch CPU budget exceeded".into());
                }
                frame.instances.push(patch.apply(&base.recipe)?);
            }
            if bytes > 64 * 1024 * 1024 {
                return Err("scene CPU budget exceeded".into());
            }
            Ok(frame)
        } else {
            let mut frame: Frame =
                serde_json::from_slice(bytes).map_err(|error| format!("invalid scene: {error}"))?;
            for mesh in &mut frame.meshes {
                mesh.reversed_depth = frame.settings.reversed_depth();
            }
            Ok(frame)
        }
    }
    pub fn scene_draw_stats(&self) -> (u64, usize) {
        (
            self.last_scene_draws.get(),
            self.pipelines.len()
                + usize::from(self.energy_lut.table.is_some())
                + usize::from(
                    self.transmission
                        .targets
                        .as_ref()
                        .is_some_and(|t| t.seed.is_some()),
                ),
        )
    }
    pub fn scene_resource_stats(&self) -> (u64, u64) {
        self.resources.stats()
    }
    pub fn close_scene_view(&mut self, view: u64) -> Result<(), String> {
        self.close_batches(view)?;
        let keys = self.draw_cache.borrow_mut().remove(view);
        for key in keys {
            self.resources
                .release_scene_resource(key)
                .map_err(|e| e.to_string())?;
        }
        self.views.remove(&view);
        self.staging.remove(&view);
        self.close_energy_lut(view)?;
        if self
            .compositor
            .resized
            .as_ref()
            .is_some_and(|t| t.view == view)
        {
            let state = self.state.as_mut().unwrap();
            let target = state.compositor.resized.take().unwrap();
            state
                .resources
                .release_graph(&state.device, &target.keys)
                .map_err(|e| e.to_string())?;
        }
        if let Some(bindings) = self.cover_bindings.remove(&view) {
            self.release_cover_bindings(bindings)?;
        }
        self.effects.remove(view);
        self.outlines.remove(view);
        self.shadows.remove(view);
        self.temporal.remove(view);
        let state = self.state.as_mut().unwrap();
        state
            .transmission
            .remove(view, &mut state.draw_cache.borrow_mut());
        let screen_result =
            state
                .screen_lighting
                .remove(view, &state.device, &mut state.draw_cache.borrow_mut());
        let evict_result = self.evict_geometry();
        screen_result.and(evict_result)
    }
    fn evict_geometry(&mut self) -> Result<(), String> {
        let retained: HashSet<u32> = self
            .views
            .values()
            .chain(self.staging.values())
            .flat_map(|view| view.retained.iter().copied())
            .collect();
        let removed: Vec<_> = self
            .geometries
            .keys()
            .copied()
            .filter(|id| !retained.contains(id))
            .collect();
        for id in removed {
            let geometry = self.geometries.remove(&id).unwrap();
            self.resources
                .release_scene_resource(geometry.key)
                .map_err(|e| e.to_string())?;
        }
        self.evict_textures()?;
        self.evict_instances()?;
        self.evict_poses()?;
        let state = self.state.as_mut().unwrap();
        state.resources.poll_completed(&state.device).map_err(|e| {
            state.failure = Some(e.to_string());
            e.to_string()
        })
    }
    fn prepare_scene(&mut self, frame: &Frame) -> Result<(), String> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        if let Some(admission) = &frame.admission {
            self.prepare_admission(admission)?;
        }
        let view = frame.binary.as_ref().map_or(0, |view| view.view);
        if !self.views.contains_key(&view) && self.views.len() >= 64 {
            return Err("native device view limit exceeded".into());
        }
        if self
            .views
            .iter()
            .filter(|(id, _)| **id != view)
            .map(|(_, v)| v.meshes.len())
            .sum::<usize>()
            + frame.meshes.len()
            > 16384
        {
            return Err("native device draw-state budget exceeded".into());
        }
        let mut cached: HashSet<_> = self.geometries.keys().copied().collect();
        for geometry in &frame.geometries {
            if let Some(old) = self.geometries.get(&geometry.id) {
                if old.recipe.as_ref() != geometry {
                    return Err("geometry ID refers to different immutable data".into());
                }
                if frame.binary.is_some()
                    || !self
                        .views
                        .get(&0)
                        .is_some_and(|v| v.retained.contains(&geometry.id))
                {
                    cached.remove(&geometry.id);
                }
            }
        }
        frame.validate(&cached)?;
        for mesh in &frame.meshes {
            let geometry = frame
                .geometries
                .iter()
                .find(|g| g.id == mesh.geometry)
                .or_else(|| {
                    self.geometries
                        .get(&mesh.geometry)
                        .map(|g| g.recipe.as_ref())
                })
                .ok_or("missing primitive geometry")?;
            let kind = match geometry.topology {
                0 => 0,
                1 | 2 => 1,
                _ => 2,
            };
            if mesh.vertex_colors && (geometry.colors.is_empty() || mesh.shader.is_some()) {
                return Err("Vertex colors require a color attribute and built-in material".into());
            }
            if kind != mesh.primitive_kind {
                return Err("material and geometry topology mismatch".into());
            }
        }
        let (pose_bytes, pose_count) = self.validate_poses(frame)?;
        for mesh in &frame.meshes {
            if mesh.anisotropic() {
                let geometry = frame
                    .geometries
                    .iter()
                    .find(|g| g.id == mesh.geometry)
                    .or_else(|| {
                        self.geometries
                            .get(&mesh.geometry)
                            .map(|g| g.recipe.as_ref())
                    })
                    .ok_or("missing anisotropic geometry")?;
                if geometry.tangents.is_empty() {
                    return Err("anisotropy requires geometry tangents".into());
                }
            }
        }
        let (texture_bytes, texture_count) = self.validate_textures(frame)?;
        let (reusable_instances, instance_bytes, instance_count) =
            self.validate_instances(frame)?;
        let reusable: HashMap<u32, u32> = frame
            .geometry_patches
            .iter()
            .filter(|patch| {
                frame.admission.is_none()
                    && !self.geometries.contains_key(&patch.id)
                    && frame
                        .geometry_patches
                        .iter()
                        .filter(|p| p.base == patch.base)
                        .count()
                        == 1
                    && frame
                        .binary
                        .as_ref()
                        .is_some_and(|v| !v.retained.contains(&patch.base))
                    && !self
                        .views
                        .iter()
                        .any(|(id, v)| *id != view && v.retained.contains(&patch.base))
                    && !self
                        .staging
                        .values()
                        .any(|v| v.retained.contains(&patch.base))
            })
            .map(|p| (p.id, p.base))
            .collect();
        let bytes: usize = frame
            .geometries
            .iter()
            .filter(|g| !self.geometries.contains_key(&g.id) && !reusable.contains_key(&g.id))
            .map(|g| g.byte_length())
            .sum();
        let mut draw_plan = self.draw_cache.borrow().plan(frame);
        let asset_bytes = (bytes + texture_bytes + instance_bytes + pose_bytes) as u64;
        let asset_count = frame
            .geometries
            .iter()
            .filter(|g| !self.geometries.contains_key(&g.id) && !reusable.contains_key(&g.id))
            .count()
            + texture_count
            + instance_count
            + pose_count;
        loop {
            let reclaimed = self.draw_cache.borrow().reclaimed_keys(&draw_plan);
            match self.resources.check_scene_capacity_after_release(
                asset_bytes + draw_plan.additional_bytes,
                asset_count + draw_plan.additional_count,
                &reclaimed,
            ) {
                Ok(()) => break,
                Err(crate::resources::ResourceError::BudgetExceeded)
                    if self.draw_cache.borrow().reclaim_older_view(&mut draw_plan) =>
                {
                    continue;
                }
                Err(error) => return Err(error.to_string()),
            }
        }
        // Preflight all CPU validation before any existing ownership changes.
        self.begin_draw_cache(draw_plan)?;
        for geometry in &frame.geometries {
            if !self.geometries.contains_key(&geometry.id) {
                let state = self.state.as_mut().unwrap();
                let patch = frame.geometry_patches.iter().find(|p| p.id == geometry.id);
                let result = if let Some(patch) = patch {
                    let base_key = state.geometries[&patch.base].key;
                    state.resources.patch_geometry(
                        &state.device,
                        &state.queue,
                        base_key,
                        geometry,
                        patch,
                        reusable.contains_key(&geometry.id),
                    )
                } else {
                    state.resources.insert_geometry(&state.device, geometry)
                };
                let key = result.map_err(|e| {
                    state.failure = Some(e.to_string());
                    e.to_string()
                })?;
                if let Some(base) = reusable.get(&geometry.id) {
                    state.geometries.remove(base);
                }
                state.geometries.insert(
                    geometry.id,
                    GpuGeometry {
                        key,
                        recipe: std::sync::Arc::new(geometry.clone()),
                        center: draw_order::geometry_center(geometry),
                        bounds: batching::Bounds::geometry(geometry),
                        deformation_bounds: crate::deformation::SourceBounds::new(geometry),
                    },
                );
            }
        }
        self.upload_textures(frame)?;
        self.upload_instances(frame, &reusable_instances)?;
        self.upload_poses(frame)?;
        Ok(())
    }

    fn commit_scene(&mut self, frame: &Frame) -> Result<(), String> {
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        let state = frame
            .binary
            .clone()
            .unwrap_or_else(|| crate::scene_packet::ViewState {
                view: 0,
                revision: 0,
                retained: frame.meshes.iter().map(|m| m.geometry).collect(),
                meshes: Vec::new(),
                retained_instances: HashSet::new(),
                retained_poses: HashSet::new(),
                retained_textures: frame
                    .meshes
                    .iter()
                    .flat_map(|m| m.texture_maps().map(|map| map.texture))
                    .collect(),
            });
        self.retain_cover_bindings(frame)?;
        self.views.insert(view, state);
        if frame.admission.as_ref().is_none_or(|a| a.publish) {
            self.staging.remove(&view);
        }
        self.commit_energy_lut(frame)?;
        self.evict_geometry()
    }

    fn prepare_pipelines(
        &mut self,
        frame: &Frame,
        format: wgpu::TextureFormat,
    ) -> Result<(), String> {
        let state = self.state.as_mut().unwrap();
        let mut requests = Vec::new();
        if state.outlines.view(frame).is_some() {
            requests.push((outlines::FORMAT, frame.sample_count(), true));
        }
        if let Some(targets) = &state.transmission.targets
            && (targets.format != format || targets.samples != frame.sample_count())
        {
            requests.push((targets.format, targets.samples, false));
        }
        if frame
            .settings
            .screen_lighting
            .as_ref()
            .is_some_and(screen_lighting::Settings::enabled)
        {
            requests.push((screen_lighting::FORMAT, 1, false));
        }
        requests.push((format, frame.sample_count(), false));
        let result = state.pipelines.prepare(
            &state.device,
            frame,
            &requests,
            |id| !state.geometries[&id].recipe.tangents.is_empty(),
            &state.batches.leaders.keys().copied().collect(),
        );
        let retired = state.pipelines.take_retired_layouts();
        state.draw_cache.borrow_mut().invalidate_layouts(&retired);
        result
    }

    pub(crate) fn begin_profile(&mut self) {
        self.resources.pin_batch(false);
        *self.profile.borrow_mut() = timing::Profile {
            status: if self.failure.is_some() {
                "failed"
            } else {
                "incomplete"
            },
            ..Default::default()
        };
        self.last_gpu_time_ns = None;
        self.gpu_time_source = "unavailable";
    }
    #[cfg(target_vendor = "apple")]
    pub(crate) fn has_failed_surface(&self) -> bool {
        self.failed_surface.is_some()
    }
    #[cfg(target_vendor = "apple")]
    pub(crate) fn reject_frame(&mut self) {
        self.resources.pin_batch(false);
        self.profile.borrow_mut().status = "failed";
    }
    pub(crate) fn fail_frame(&mut self, error: String) -> String {
        self.resources.pin_batch(false);
        let _ = self.clear_batches();
        self.clear_draw_cache();
        self.failure = Some(error.clone());
        self.last_gpu_time_ns = None;
        self.gpu_time_source = "unavailable";
        let mut profile = self.profile.borrow_mut();
        profile.status = "failed";
        profile.gpu_time_ns = None;
        profile.gpu_time_source = "unavailable";
        for pass in profile.passes.values_mut() {
            pass.gpu_time_ns = None;
        }
        error
    }

    fn begin_pass(&self, encoder: &mut wgpu::CommandEncoder, pass: timing::Pass) {
        self.profile
            .borrow_mut()
            .passes
            .get_mut(timing::PASSES[pass as usize])
            .unwrap()
            .executed = true;
        if let Some(timer) = &self.gpu_timer {
            timer.begin_pass(encoder, pass);
        }
    }
    fn end_pass(&self, encoder: &mut wgpu::CommandEncoder, pass: timing::Pass) {
        if let Some(timer) = &self.gpu_timer {
            timer.end_pass(encoder, pass);
        }
    }

    fn encode_scene(
        &self,
        frame: &Frame,
        attachments: (
            &wgpu::TextureView,
            Option<&wgpu::TextureView>,
            &wgpu::TextureView,
            bool,
        ),
        format: wgpu::TextureFormat,
        size: [u32; 2],
        composition: (
            &[Option<crate::render_graph::PreparedMaterial>],
            Option<&crate::render_graph::FrameGraph>,
            &environment::PreparedEnvironment,
            &shadows::PreparedShadows,
        ),
    ) -> wgpu::CommandEncoder {
        let (color_view, resolve_target, depth_view, load_depth) = attachments;
        let (materials, graph, environment, shadows) = composition;
        let vp = Mat4::from_cols_array(&self.temporal.vp(frame));
        let lighting = frame.meshes.iter().any(|m| m.pbr.is_some()).then(|| {
            self.draw_uniform(
                draw_cache::UniformKey::Lighting,
                bytemuck::bytes_of(&crate::lighting::LightingUniform::capture(
                    &frame.lights,
                    &frame.hemispheres,
                    &frame.areas,
                )),
            )
        });
        let screen_uniforms = lighting.as_ref().map(|_| {
            [
                self.screen_lighting_uniform(frame, false),
                self.screen_lighting_uniform(frame, true),
            ]
        });
        let make_bindings = |capture: bool, screen_source: bool| -> Vec<_> {
            let size = if capture && !screen_source {
                self.transmission.targets.as_ref().map_or(size, |t| t.size)
            } else {
                size
            };
            frame
                .meshes
                .iter()
                .enumerate()
                .map(|(index, source)| {
                    let mesh = self.batches.leaders.get(&index).map_or(source, |b| &b.mesh);
                    if self.batches.skipped.contains(&index)
                        || !mesh.color_visible
                        || (capture && (mesh.requires_opaque_capture() || mesh.alpha_mode == 2))
                    {
                        return None;
                    }
                    let model = Mat4::from_cols_array(&mesh.model);
                    let mut pbr_maps = [0; 4];
                    if let Some(pbr) = &mesh.pbr {
                        for (i, map) in [
                            mesh.color_map.as_ref(),
                            pbr.normal_map.as_ref(),
                            pbr.metallic_roughness_map.as_ref(),
                            pbr.occlusion_map.as_ref(),
                            pbr.emissive_map.as_ref(),
                        ]
                        .into_iter()
                        .enumerate()
                        {
                            if let Some(map) = map {
                                pbr_maps[0] |= 1 << i;
                                pbr_maps[1] |= map.uv_set << i;
                            }
                        }
                    }
                    if let Some(pbr) = &mesh.pbr {
                        for (i, map) in pbr.physical_maps.iter().enumerate() {
                            if let Some(map) = map {
                                pbr_maps[3] |= map.uv_set << i;
                            }
                        }
                    }
                    let uniforms = Uniforms {
                        transmission: {
                            let t = mesh.pbr.as_ref().map_or([0.; 8], |p| p.transmission);
                            [t[..4].try_into().unwrap(), t[4..].try_into().unwrap()]
                        },
                        optical: {
                            let o = mesh.pbr.as_ref().map_or([0.; 8], |p| p.optical);
                            [o[..4].try_into().unwrap(), o[4..].try_into().unwrap()]
                        },
                        capture_projection: vp.to_cols_array(),
                        inverse_view_projection: vp.inverse().to_cols_array(),
                        clipping_planes: section_planes(mesh),
                        clipping: [
                            mesh.clipping_planes.len() as f32,
                            mesh.coverage[0],
                            mesh.coverage[1],
                            if mesh.reversed_depth { 1. } else { 0. },
                        ],
                        physical: {
                            let p = mesh.pbr.as_ref().and_then(|p| p.physical).unwrap_or([
                                1.5, 1., 0., 0., 1., 1., 1., 1., 0., 0., 0., 0., 0., 0., 0., 0.,
                            ]);
                            [
                                p[0..4].try_into().unwrap(),
                                p[4..8].try_into().unwrap(),
                                p[8..12].try_into().unwrap(),
                                p[12..16].try_into().unwrap(),
                            ]
                        },
                        pbr_maps,
                        pbr_factors: mesh.pbr.as_ref().map_or([0.; 4], |p| {
                            [
                                p.normal_scale,
                                p.occlusion_strength,
                                model.determinant().signum(),
                                p.normal_scale_y,
                            ]
                        }),
                        pbr_params: mesh.pbr.as_ref().map_or([0.; 4], |p| {
                            [
                                p.metallic,
                                p.roughness,
                                if mesh.receive_shadow { 1. } else { 0. },
                                p.specular_aa[0],
                            ]
                        }),
                        emissive: mesh.pbr.as_ref().map_or([0.; 4], |p| {
                            [
                                p.emissive[0],
                                p.emissive[1],
                                p.emissive[2],
                                p.specular_aa[1],
                            ]
                        }),
                        mvp: (vp * model).to_cols_array(),
                        normal_matrix: model.inverse().transpose().to_cols_array(),
                        color_unlit: [
                            mesh.color[0],
                            mesh.color[1],
                            mesh.color[2],
                            if mesh.unlit { 1.0 } else { 0.0 },
                        ],
                        light_ambient: [
                            frame.light_direction[0],
                            frame.light_direction[1],
                            frame.light_direction[2],
                            frame.ambient,
                        ],
                        view_projection: frame.view_projection,
                        model: mesh.model,
                        primitive: [
                            mesh.primitive_size,
                            mesh.size_units as f32,
                            mesh.point_shape as f32,
                            0.,
                        ],
                        viewport: [
                            size[0] as f32,
                            size[1] as f32,
                            if mesh.instances != 0 || self.batches.leaders.contains_key(&index) {
                                mesh.side as f32
                            } else {
                                0.
                            },
                            0.,
                        ],
                        map_params: [
                            mesh.color_map.as_ref().map_or(0., |map| map.uv_set as f32),
                            mesh.opacity,
                            mesh.alpha_cutoff,
                            mesh.alpha_mode as f32,
                        ],
                    };
                    let buffer = self.draw_uniform(
                        draw_cache::UniformKey::Mesh(index, capture),
                        bytemuck::bytes_of(&uniforms),
                    );
                    let mut entries = vec![wgpu::BindGroupEntry {
                        binding: 0,
                        resource: buffer.as_entire_binding(),
                    }];
                    if mesh.pbr.is_some() {
                        entries.push(wgpu::BindGroupEntry {
                            binding: 1,
                            resource: lighting.as_ref().unwrap().as_entire_binding(),
                        });
                        entries.extend(
                            environment
                                .for_mesh(index)
                                .entries(&self.environment_defaults),
                        );
                        entries.extend(shadows.entries(&self.shadows));
                        entries.extend(self.area_tables.entries());
                        entries.extend(self.transmission.entries(capture));
                        entries.extend(self.screen_lighting.entries(
                            screen_source,
                            &screen_uniforms.as_ref().unwrap()[usize::from(screen_source)],
                        ));
                    }
                    Some(self.draw_binding(
                        draw_cache::BindingKey(
                            index,
                            if screen_source { 5 } else { u8::from(capture) },
                        ),
                        if mesh.pbr.is_some() {
                            &self.pbr_layout
                        } else {
                            &self.layout
                        },
                        &entries,
                    ))
                })
                .collect()
        };
        let bindings = make_bindings(false, false);
        let screen_enabled = frame
            .settings
            .screen_lighting
            .as_ref()
            .is_some_and(screen_lighting::Settings::enabled);
        let source_bindings = screen_enabled.then(|| make_bindings(true, true));
        if let Some(settings) = frame
            .settings
            .screen_lighting
            .as_ref()
            .filter(|_| screen_enabled)
        {
            let mut profile = self.profile.borrow_mut();
            profile.screen_lighting_ao_samples = if settings.ao {
                [8, 12, 16][settings.quality as usize]
            } else {
                0
            };
            profile.screen_lighting_reflection_steps = if settings.reflections {
                [16, 32, 64][settings.quality as usize]
            } else {
                0
            };
            for mesh in frame.meshes.iter().filter(|m| m.color_visible) {
                let ao = mesh.pbr.is_some()
                    && mesh.shader.is_none()
                    && mesh.material_shader.is_none()
                    && !mesh.scene_inputs
                    && mesh.alpha_mode != 2
                    && mesh.pbr.as_ref().is_some_and(|p| p.transmission[0] == 0.);
                let reflection = ao && pipelines::active_lobes(mesh) & 30 == 0;
                profile.screen_lighting_ao_meshes += usize::from(ao && settings.ao);
                profile.screen_lighting_reflection_meshes +=
                    usize::from(reflection && settings.reflections);
                profile.screen_lighting_excluded_meshes +=
                    usize::from(!(ao && settings.ao || reflection && settings.reflections));
            }
        }

        let capture_bindings = self
            .transmission
            .targets
            .as_ref()
            .map(|_| make_bindings(true, false));
        let texture_bindings: Vec<_> = frame
            .meshes
            .iter()
            .enumerate()
            .map(|(index, mesh)| {
                mesh.color_visible
                    .then(|| self.texture_binding(index, mesh))
                    .flatten()
            })
            .collect();
        let scene_input_bindings = self.scene_input_bindings(frame, size, materials);
        let physical_bindings: Vec<_> = frame
            .meshes
            .iter()
            .enumerate()
            .map(|(index, mesh)| {
                mesh.color_visible
                    .then(|| self.physical_texture_binding(index, mesh))
                    .flatten()
            })
            .collect();
        let mut encoder = self.device.create_command_encoder(&Default::default());
        if let Some(timer) = &self.gpu_timer {
            timer.begin(&mut encoder);
        }
        self.encode_energy_lut(&mut encoder, frame);
        if let Some(graph) = graph.filter(|graph| graph.has_before()) {
            self.begin_pass(&mut encoder, timing::Pass::ResourceGraphBefore);
            graph.encode_before(&mut encoder);
            self.end_pass(&mut encoder, timing::Pass::ResourceGraphBefore);
        }
        if shadows.renders() {
            self.begin_pass(&mut encoder, timing::Pass::Shadows);
        }
        shadows.encode(self, frame, &mut encoder);
        if shadows.renders() {
            self.end_pass(&mut encoder, timing::Pass::Shadows);
        }
        self.last_scene_draws.set(0);
        self.last_instance_draws.set(0);
        {
            let mut p = self.profile.borrow_mut();
            p.executed_mesh_draws = Some(0);
            p.opaque_batch_draws = Some(0);
            p.batched_source_draws = Some(0);
            p.pipeline_switches = Some(0);
            p.bind_group_switches = Some(0);
        }
        let reuse_opaque = self.reuse_opaque_capture(frame, format, load_depth);
        for (capture, mask, source) in [
            (true, false, true),
            (true, false, false),
            (false, false, false),
            (false, true, false),
        ] {
            if source && !screen_enabled {
                continue;
            }
            if mask && self.outlines.view(frame).is_none() {
                continue;
            }
            if capture && !source && self.transmission.targets.is_none() {
                continue;
            }
            let pass_kind = if source {
                timing::Pass::ScreenLightingSource
            } else if capture {
                timing::Pass::Transmission
            } else if mask {
                timing::Pass::OutlineMask
            } else {
                timing::Pass::Scene
            };
            self.begin_pass(&mut encoder, pass_kind);
            self.profile
                .borrow_mut()
                .passes
                .get_mut(timing::PASSES[pass_kind as usize])
                .unwrap()
                .draw_calls = Some(0);
            let (color_view, resolve_target, depth_view) = if source {
                let t = self.screen_lighting.targets.as_ref().unwrap();
                (&t.color, None, &t.depth)
            } else if capture {
                let t = self.transmission.targets.as_ref().unwrap();
                if let Some(msaa) = &t.multisample {
                    (&msaa.color, Some(&t.color), &msaa.depth)
                } else {
                    (&t.color, None, &t.depth)
                }
            } else {
                (color_view, resolve_target, depth_view)
            };
            let (color_view, resolve_target, format) = if mask {
                let view = self.outlines.view(frame).unwrap();
                (view.attachment(), view.resolve(), outlines::FORMAT)
            } else {
                (
                    color_view,
                    resolve_target,
                    if source {
                        screen_lighting::FORMAT
                    } else if capture {
                        self.transmission.targets.as_ref().unwrap().format
                    } else {
                        format
                    },
                )
            };
            let bindings = if source {
                source_bindings.as_ref().unwrap()
            } else if capture {
                capture_bindings.as_ref().unwrap()
            } else {
                &bindings
            };
            let materials = if mask {
                &self.outline_materials[..]
            } else if source {
                &self.screen_lighting.materials[..]
            } else if capture {
                &self.transmission.materials[..]
            } else {
                materials
            };
            let samples = if source {
                1
            } else if capture {
                self.transmission.targets.as_ref().unwrap().samples
            } else {
                frame.sample_count()
            };
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("native frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: color_view,
                    resolve_target,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(if mask {
                            wgpu::Color::TRANSPARENT
                        } else {
                            wgpu::Color {
                                r: frame.background[0] * f64::from(frame.background_alpha),
                                g: frame.background[1] * f64::from(frame.background_alpha),
                                b: frame.background[2] * f64::from(frame.background_alpha),
                                a: f64::from(frame.background_alpha),
                            }
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: depth_view,
                    depth_ops: Some(wgpu::Operations {
                        load: if mask || (load_depth && !capture) {
                            wgpu::LoadOp::Load
                        } else {
                            wgpu::LoadOp::Clear(frame.settings.depth_clear())
                        },
                        store: if load_depth
                            || capture
                            || frame.temporal.is_some()
                            || frame.settings.enabled
                            || self.sensor_depth_capture
                            || self.outlines.view(frame).is_some()
                        {
                            wgpu::StoreOp::Store
                        } else {
                            wgpu::StoreOp::Discard
                        },
                    }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            if reuse_opaque && !capture && !mask {
                let (pipeline, binding) = self
                    .transmission
                    .targets
                    .as_ref()
                    .unwrap()
                    .seed
                    .as_ref()
                    .unwrap();
                pass.set_pipeline(pipeline);
                pass.set_bind_group(0, binding, &[]);
                pass.draw(0..3, 0..1);
                self.last_scene_draws.set(self.last_scene_draws.get() + 1);
                let mut profile = self.profile.borrow_mut();
                *profile
                    .passes
                    .get_mut("scene")
                    .unwrap()
                    .draw_calls
                    .as_mut()
                    .unwrap() += 1;
                *profile.pipeline_switches.as_mut().unwrap() += 1;
                *profile.bind_group_switches.as_mut().unwrap() += 1;
            }
            let mut previous_pipeline = None;
            let mut previous_bindings: [Option<&wgpu::BindGroup>; 4] = [None; 4];
            for draw in &self.batches.order {
                if self.batches.skipped.contains(&draw.mesh) {
                    continue;
                }
                if mask && !frame.meshes[draw.mesh].outlined {
                    continue;
                }
                if capture
                    && (frame.meshes[draw.mesh].requires_opaque_capture()
                        || frame.meshes[draw.mesh].alpha_mode == 2)
                {
                    continue;
                }
                if reuse_opaque
                    && !capture
                    && !mask
                    && !frame.meshes[draw.mesh].requires_opaque_capture()
                    && frame.meshes[draw.mesh].alpha_mode != 2
                {
                    continue;
                }
                self.last_scene_draws.set(self.last_scene_draws.get() + 1);
                let index = draw.mesh;
                let batch = self.batches.leaders.get(&index);
                let mesh = batch.map_or(&frame.meshes[index], |b| &b.mesh);
                if mesh.instances != 0 || batch.is_some() {
                    self.last_instance_draws
                        .set(self.last_instance_draws.get() + 1);
                }
                let binding = bindings[index].as_ref().expect("visible draw prepared");
                let texture_binding = &texture_bindings[index];
                let geometry = &self.geometries[&mesh.geometry];
                if let Some(material) = &materials[index] {
                    material.bind(&mut pass);
                    *self
                        .profile
                        .borrow_mut()
                        .bind_group_switches
                        .as_mut()
                        .unwrap() += material.bind_group_count();
                    previous_pipeline = None;
                    previous_bindings = [None; 4];
                    *self
                        .profile
                        .borrow_mut()
                        .pipeline_switches
                        .as_mut()
                        .unwrap() += 1;
                } else {
                    let key = pipelines::PipelineKey::new(
                        format,
                        mesh,
                        !geometry.recipe.tangents.is_empty(),
                        samples,
                        mask,
                    )
                    .automatic(batch.is_some());
                    if previous_pipeline != Some(key) {
                        pass.set_pipeline(self.pipelines.get(key));
                        previous_pipeline = Some(key);
                        previous_bindings = [None; 4];
                        *self
                            .profile
                            .borrow_mut()
                            .pipeline_switches
                            .as_mut()
                            .unwrap() += 1;
                    }
                }
                let surface_inputs = scene_input_bindings[index].as_ref();
                for (slot, binding) in [
                    (0, Some(binding)),
                    (3, surface_inputs.or(physical_bindings[index].as_ref())),
                ] {
                    let Some(binding) = binding else {
                        continue;
                    };
                    if previous_bindings[slot] != Some(binding) {
                        pass.set_bind_group(slot as u32, binding, &[]);
                        previous_bindings[slot] = Some(binding);
                        *self
                            .profile
                            .borrow_mut()
                            .bind_group_switches
                            .as_mut()
                            .unwrap() += 1;
                    }
                }
                let (vertices, indices, count, uv, index_format) =
                    self.resources.geometry(geometry.key);
                pass.set_vertex_buffer(0, vertices.slice(..));
                if mesh.vertex_colors {
                    let textured = mesh.texture_maps().next().is_some();
                    let tangent = (textured || mesh.anisotropic())
                        && mesh.pbr.is_some()
                        && !geometry.recipe.tangents.is_empty();
                    pass.set_vertex_buffer(
                        1 + u32::from(textured) + u32::from(tangent),
                        self.resources
                            .geometry_colors(geometry.key)
                            .expect("validated color buffer")
                            .slice(..),
                    );
                }
                if let Some(material) = &materials[index] {
                    if material.uv {
                        pass.set_vertex_buffer(
                            1,
                            uv.expect("validated shader UV buffer").slice(..),
                        );
                    }
                    if material.tangent {
                        pass.set_vertex_buffer(
                            1 + u32::from(material.uv),
                            self.resources
                                .geometry_tangents(geometry.key)
                                .expect("validated shader tangent buffer")
                                .slice(..),
                        );
                    }
                    if material.colored {
                        pass.set_vertex_buffer(
                            1 + u32::from(material.uv) + u32::from(material.tangent),
                            self.resources
                                .geometry_colors(geometry.key)
                                .expect("validated shader color buffer")
                                .slice(..),
                        );
                    }
                }
                if let Some(binding) = texture_binding {
                    pass.set_vertex_buffer(1, uv.expect("validated UV buffer").slice(..));
                    if previous_bindings[1] != Some(binding) {
                        pass.set_bind_group(1, binding, &[]);
                        previous_bindings[1] = Some(binding);
                        *self
                            .profile
                            .borrow_mut()
                            .bind_group_switches
                            .as_mut()
                            .unwrap() += 1;
                    }
                }
                if mesh.pbr.is_some()
                    && (texture_binding.is_some() || mesh.anisotropic())
                    && let Some(tangents) = self.resources.geometry_tangents(geometry.key)
                {
                    pass.set_vertex_buffer(
                        1 + u32::from(texture_binding.is_some()),
                        tangents.slice(..),
                    );
                }
                pass.set_index_buffer(indices.slice(..), index_format);
                if mesh.instances != 0 || batch.is_some() {
                    let textured = mesh.texture_maps().next().is_some();
                    let tangent = (textured || mesh.anisotropic())
                        && mesh.pbr.is_some()
                        && !geometry.recipe.tangents.is_empty();
                    let buffer = self
                        .resources
                        .graph_buffer(if batch.is_some() {
                            self.batches.key.unwrap()
                        } else {
                            self.instances[&mesh.instances].key
                        })
                        .expect("validated instance buffer");
                    let slot = materials[index].as_ref().map_or(
                        1 + u32::from(textured)
                            + u32::from(tangent)
                            + u32::from(mesh.vertex_colors),
                        |material| {
                            1 + u32::from(material.uv)
                                + u32::from(material.tangent)
                                + u32::from(material.colored)
                        },
                    );
                    pass.set_vertex_buffer(slot, buffer.slice(..));
                }
                if mesh.pose != 0 {
                    let binding = &self.poses[&mesh.pose].binding;
                    if previous_bindings[2] != Some(binding) {
                        pass.set_bind_group(2, binding, &[]);
                        previous_bindings[2] = Some(binding);
                        *self
                            .profile
                            .borrow_mut()
                            .bind_group_switches
                            .as_mut()
                            .unwrap() += 1;
                    }
                }
                let instances = batch.map_or_else(|| draw.instances.clone(), |b| b.range.clone());
                pass.draw_indexed(0..count, 0, instances);
                let mut profile = self.profile.borrow_mut();
                *profile.executed_mesh_draws.as_mut().unwrap() += 1;
                *profile
                    .passes
                    .get_mut(timing::PASSES[pass_kind as usize])
                    .unwrap()
                    .draw_calls
                    .get_or_insert(0) += 1;
                if let Some(batch) = batch {
                    *profile.opaque_batch_draws.as_mut().unwrap() += 1;
                    *profile.batched_source_draws.as_mut().unwrap() += batch.range.len() as u64;
                }
            }
            drop(pass);
            if capture && !source {
                let targets = self.transmission.targets.as_ref().unwrap();
                if let (Some(msaa), Some(pipeline)) = (&targets.multisample, &targets.depth_resolve)
                {
                    multisample::resolve(
                        &self.device,
                        &mut encoder,
                        pipeline,
                        &msaa.depth,
                        &targets.depth,
                        frame.settings.depth_clear(),
                    );
                }
            }
            self.end_pass(&mut encoder, pass_kind);
        }
        encoder
    }

    fn submit(
        &mut self,
        mut encoder: wgpu::CommandEncoder,
        graph: Option<&crate::render_graph::FrameGraph>,
        materials: &[Option<crate::render_graph::PreparedMaterial>],
        environment: &environment::PreparedEnvironment,
    ) -> Result<Submission, String> {
        self.last_gpu_time_ns = None;
        self.gpu_time_source = "unavailable";
        self.draw_cache
            .borrow_mut()
            .finish(&mut self.profile.borrow_mut());
        let timing = self.gpu_timer.as_ref().map(|timer| timer.end(&mut encoder));
        let index = self.queue.submit([encoder.finish()]);
        let keys: Vec<_> = self
            .geometries
            .values()
            .map(|g| g.key)
            .chain(self.textures.values().map(|t| t.key))
            .chain(self.instances.values().map(|i| i.key))
            .chain(self.poses.values().map(|p| p.key))
            .chain(self.draw_cache.borrow().keys())
            .chain(self.batches.key)
            .chain(environment.resources.iter().copied())
            .chain(self.energy_lut.table.as_ref().map(|t| t.key))
            .chain(self.effect_resources.iter().copied())
            .chain(self.compositor.resized.iter().flat_map(|t| t.keys))
            .chain(
                materials
                    .iter()
                    .flatten()
                    .flat_map(|m| m.resources.iter().copied()),
            )
            .chain(
                graph
                    .into_iter()
                    .flat_map(|g| g.resources().iter().copied()),
            )
            .collect();
        if let Err(error) = self.resources.scene_submitted(index.clone(), &keys) {
            return Err(self.fail_frame(error.to_string()));
        }
        self.energy_lut_submitted();
        self.counters.submitted_frames += 1;
        self.profile.borrow_mut().submission_count += 1;
        #[cfg(target_vendor = "apple")]
        let metal = if self.backend == wgpu::Backend::Metal {
            match crate::interop::metal::MetalCompletion::capture(&self.queue) {
                Ok(completion) => Some(completion),
                Err(error) => {
                    return Err(self.fail_frame(error));
                }
            }
        } else {
            None
        };
        Ok(Submission {
            index,
            timing,
            #[cfg(target_vendor = "apple")]
            metal,
        })
    }

    fn wait_for_submission(&mut self, submission: Submission) -> Result<(), String> {
        self.last_gpu_time_ns = None;
        let wait_started = std::time::Instant::now();
        let result = self
            .device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(submission.index),
                timeout: Some(Duration::from_secs(2)),
            })
            .map(|_| ())
            .map_err(|error| error.to_string());
        #[cfg(target_vendor = "apple")]
        let result = result.and_then(|()| match submission.metal {
            Some(completion) => {
                completion.check()?;
                self.last_gpu_time_ns = completion.gpu_time_ns();
                if self.last_gpu_time_ns.is_some() {
                    self.gpu_time_source = "metal.commandBuffer.startEndTime";
                }
                Ok(())
            }
            None => Ok(()),
        });
        self.profile.borrow_mut().cpu_completion_wait_ns =
            Some(wait_started.elapsed().as_nanos() as u64);
        if result.is_ok() {
            if let Some(timing) = submission.timing {
                self.diagnostic_readback_bytes = self
                    .diagnostic_readback_bytes
                    .saturating_add(timing.copied_bytes());
                let measured = timing.read(&mut self.profile.borrow_mut());
                self.last_gpu_time_ns = measured;
                if self.last_gpu_time_ns.is_some() {
                    self.gpu_time_source = "wgpu.timestampQuery.commandEncoder";
                }
            }
            if let Err(error) = self.resources.scene_completed() {
                return Err(self.fail_frame(format!(
                    "GPU resource completion failed; recreate this renderer: {error}"
                )));
            }
            let mut profile = self.profile.borrow_mut();
            profile.gpu_time_ns = self.last_gpu_time_ns;
            profile.gpu_time_source = self.gpu_time_source;
        }
        result.map_err(|error| {
            let message = format!("GPU completion failed; recreate this renderer: {error}");
            self.fail_frame(message)
        })
    }

    /// Platform adapter has observed device idle or device loss before release.
    #[cfg(target_os = "android")]
    pub(crate) fn release_completed_external_targets(&mut self) {
        self.failed_surface = None;
        self.failed_surface_depth = None;
    }

    #[cfg(any(target_vendor = "apple", target_os = "android"))]
    pub(crate) fn render_to_surface(
        &mut self,
        frame: &Frame,
        texture: wgpu::Texture,
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        self.render_to_surface_with_depth(frame, texture, None, width, height)
    }

    #[cfg(any(target_vendor = "apple", target_os = "android"))]
    pub(crate) fn render_to_surface_with_depth(
        &mut self,
        frame: &Frame,
        texture: wgpu::Texture,
        initialized_depth: Option<wgpu::Texture>,
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        self.render_to_target(frame, texture, initialized_depth, width, height, None)
    }

    fn render_to_target(
        &mut self,
        frame: &Frame,
        texture: wgpu::Texture,
        initialized_depth: Option<wgpu::Texture>,
        width: u32,
        height: u32,
        capture: Option<crate::resources::registry::ResourceKey>,
    ) -> Result<(), String> {
        self.begin_profile();
        let prepare_started = std::time::Instant::now();
        let upload_before = self.resources.stats().1;
        pixel_len(width, height)?;
        if initialized_depth.is_some() {
            Self::check_external_depth_frame(frame)?;
        }
        self.check_shadows(frame)?;
        self.check_physical_bindings(frame)?;
        let graph = self.resolve_frame_graph(frame, width, height)?;
        if initialized_depth.is_some()
            && graph
                .as_ref()
                .is_some_and(|g| g.scene_color.width() != width || g.scene_color.height() != height)
        {
            return Err("retained graph resize requires internally owned depth".into());
        }
        let render_size =
            self.prepare_retained_size(frame, graph.as_ref(), [width, height], texture.format())?;
        self.check_temporal(frame, render_size)?;
        self.prepare_energy_lut(frame)?;
        let environment = self.prepare_environment(frame, graph.as_ref())?;
        let materials = self.prepare_materials(frame, texture.format(), graph.as_ref())?;
        let scene_format = composition::scene_format(frame, texture.format(), graph.as_ref())?;
        // Attachment rejection must precede scene revisions and reusable-buffer edits.
        self.prepare_frame_targets(
            frame,
            texture.format(),
            render_size,
            graph.as_ref(),
            capture.is_none(),
        )?;
        self.prepare_screen_lighting(frame, render_size, graph.as_ref())?;
        self.prepare_transmission(frame, scene_format, render_size, graph.as_ref())?;
        self.prepare_scene(frame)?;
        self.outline_materials = if self.outlines.view(frame).is_some() {
            self.prepare_materials_in_format(
                frame,
                outlines::FORMAT,
                None,
                frame.sample_count(),
                true,
            )?
        } else {
            vec![]
        };
        let mut environment = environment.prepare(self, frame);
        if let Some(key) = capture {
            if environment.resources.contains(&key)
                || materials
                    .iter()
                    .flatten()
                    .any(|m| m.resources.contains(&key))
                || graph.as_ref().is_some_and(|g| g.resources().contains(&key))
            {
                return Err("Capture target cannot also be a frame input".into());
            }
            environment.resources.push(key);
        }
        let shadows = self.prepare_shadows(frame)?;
        self.prepare_temporal(frame, render_size)?;
        self.prepare_batches(frame)?;
        self.prepare_pipelines(frame, scene_format)?;
        self.commit_scene(frame)?;
        if initialized_depth.is_none()
            && self
                .surface_depth
                .as_ref()
                .is_none_or(|target| target.width != width || target.height != height)
        {
            let depth = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("shared frame depth"),
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            self.surface_depth = Some(DepthTarget {
                width,
                height,
                view: depth.create_view(&Default::default()),
                _texture: depth,
            });
        }
        let supplied_depth = initialized_depth
            .as_ref()
            .map(|depth| depth.create_view(&Default::default()));
        self.profile.borrow_mut().cpu_prepare_ns =
            Some(prepare_started.elapsed().as_nanos() as u64);
        self.profile.borrow_mut().upload_bytes =
            self.resources.stats().1.saturating_sub(upload_before);
        self.resources.pin_batch(true);
        let encode_started = std::time::Instant::now();
        let encoder = self.encode_frame(
            frame,
            &texture.create_view(&Default::default()),
            supplied_depth
                .as_ref()
                .unwrap_or_else(|| &self.surface_depth.as_ref().unwrap().view),
            texture.format(),
            render_size,
            (
                graph.as_ref(),
                &materials,
                capture.is_none(),
                &environment,
                &shadows,
                initialized_depth.is_some(),
            ),
        );
        self.profile.borrow_mut().cpu_encode_ns = Some(encode_started.elapsed().as_nanos() as u64);
        let result = self
            .submit(encoder, graph.as_ref(), &materials, &environment)
            .and_then(|submission| {
                if capture.is_some() {
                    let state = self.state.as_mut().unwrap();
                    state.resources.track_queued_scene(&state.queue);
                    Ok(())
                } else {
                    self.wait_for_submission(submission)
                }
            });
        if let Err(error) = result {
            // Stop future submissions and keep the imported resource owned.
            self.failed_surface = Some(texture);
            self.failed_surface_depth = initialized_depth;
            return Err(error);
        }
        self.accept_shadows(shadows);
        self.temporal.accept();
        self.accept_history(frame);
        self.profile.borrow_mut().status = if capture.is_some() {
            "queued"
        } else {
            "complete"
        };
        Ok(())
    }

    /// Supplied depth must remain the main scene attachment for every draw.
    pub(crate) fn check_external_depth_frame(frame: &Frame) -> Result<(), String> {
        if frame.settings.enabled
            || frame
                .settings
                .screen_lighting
                .as_ref()
                .is_some_and(screen_lighting::Settings::enabled)
            || frame.temporal.is_some()
            || frame.sample_count() != 1
            || frame
                .meshes
                .iter()
                .any(|mesh| mesh.requires_opaque_capture())
        {
            return Err("initialized external depth does not support effects, temporal rendering, multisampling or transmission capture".into());
        }
        Ok(())
    }

    fn copy_readback(
        &mut self,
        readback: &wgpu::Buffer,
        width: u32,
        stride: u32,
        len: usize,
        mapped_result: Result<(), String>,
    ) -> Result<Vec<u8>, String> {
        if let Err(error) = mapped_result {
            return Err(self.fail_frame(error));
        }
        let mapped = match readback.slice(..).get_mapped_range() {
            Ok(mapped) => mapped,
            Err(error) => return Err(self.fail_frame(error.to_string())),
        };
        let mut pixels = Vec::with_capacity(len);
        for row in mapped.chunks_exact(stride as usize) {
            pixels.extend_from_slice(&row[..width as usize * 4]);
        }
        drop(mapped);
        readback.unmap();
        Ok(pixels)
    }

    pub fn render(&mut self, frame: &Frame, width: u32, height: u32) -> Result<Vec<u8>, String> {
        self.render_sensor(frame, width, height, false)
            .map(|value| value.0)
    }

    pub fn render_sensor(
        &mut self,
        frame: &Frame,
        width: u32,
        height: u32,
        depth: bool,
    ) -> Result<(Vec<u8>, Option<Vec<u8>>), String> {
        if depth
            && (!frame.settings.effects.is_empty()
                || (frame.sample_count() != 1 && !frame.settings.enabled)
                || frame.temporal.is_some()
                || frame.graph.is_some())
        {
            return Err(
                "Sensor depth excludes custom screen effects, temporal AA and frame graphs".into(),
            );
        }
        self.begin_profile();
        let prepare_started = std::time::Instant::now();
        let upload_before = self.resources.stats().1;
        let len = pixel_len(width, height)?;
        self.check_shadows(frame)?;
        self.check_physical_bindings(frame)?;
        let graph = self.resolve_frame_graph(frame, width, height)?;
        let render_size = self.prepare_retained_size(
            frame,
            graph.as_ref(),
            [width, height],
            wgpu::TextureFormat::Rgba8UnormSrgb,
        )?;
        self.check_temporal(frame, render_size)?;
        self.prepare_energy_lut(frame)?;
        let environment = self.prepare_environment(frame, graph.as_ref())?;
        let materials =
            self.prepare_materials(frame, wgpu::TextureFormat::Rgba8UnormSrgb, graph.as_ref())?;
        let scene_format =
            composition::scene_format(frame, wgpu::TextureFormat::Rgba8UnormSrgb, graph.as_ref())?;
        self.prepare_frame_targets(
            frame,
            wgpu::TextureFormat::Rgba8UnormSrgb,
            render_size,
            graph.as_ref(),
            false,
        )?;
        self.prepare_screen_lighting(frame, render_size, graph.as_ref())?;
        self.prepare_transmission(frame, scene_format, render_size, graph.as_ref())?;
        self.prepare_scene(frame)?;
        self.outline_materials = if self.outlines.view(frame).is_some() {
            self.prepare_materials_in_format(
                frame,
                outlines::FORMAT,
                None,
                frame.sample_count(),
                true,
            )?
        } else {
            vec![]
        };
        let environment = environment.prepare(self, frame);
        let shadows = self.prepare_shadows(frame)?;
        self.prepare_temporal(frame, render_size)?;
        self.prepare_batches(frame)?;
        self.prepare_pipelines(frame, scene_format)?;
        self.commit_scene(frame)?;
        self.resize(width, height);
        if depth {
            self.prepare_sensor_depth();
        }
        self.profile.borrow_mut().cpu_prepare_ns =
            Some(prepare_started.elapsed().as_nanos() as u64);
        self.profile.borrow_mut().upload_bytes =
            self.resources.stats().1.saturating_sub(upload_before);
        self.resources.pin_batch(true);
        let encode_started = std::time::Instant::now();
        self.sensor_depth_capture = depth;
        let target = self.targets.as_ref().unwrap();
        let mut encoder = self.encode_frame(
            frame,
            &target.color_view,
            &target.depth_view,
            wgpu::TextureFormat::Rgba8UnormSrgb,
            render_size,
            (
                graph.as_ref(),
                &materials,
                false,
                &environment,
                &shadows,
                false,
            ),
        );
        encoder.copy_texture_to_buffer(
            target.color.as_image_copy(),
            wgpu::TexelCopyBufferInfo {
                buffer: &target.readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(target.stride),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        let depth_readback = if depth {
            Some(self.encode_sensor_depth(&mut encoder, frame))
        } else {
            None
        };
        let readback = target.readback.clone();
        let stride = target.stride;
        self.sensor_depth_capture = false;
        self.profile.borrow_mut().cpu_encode_ns = Some(encode_started.elapsed().as_nanos() as u64);
        let submission = self.submit(encoder, graph.as_ref(), &materials, &environment)?;
        let slice = readback.slice(..);
        let (sender, receiver) = mpsc::sync_channel(1);
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.wait_for_submission(submission)?;
        let mapped_result = receiver
            .recv_timeout(Duration::from_secs(1))
            .map_err(|error| format!("readback callback failed: {error}"))
            .and_then(|result| result.map_err(|error| format!("readback failed: {error}")));
        let readback_started = std::time::Instant::now();
        let pixels = self.copy_readback(&readback, width, stride, len, mapped_result)?;
        let depth_pixels = depth_readback
            .map(|buffer| self.read_sensor_depth(&buffer, width, stride, len))
            .transpose()?;
        self.profile.borrow_mut().cpu_readback_ns =
            Some(readback_started.elapsed().as_nanos() as u64);
        self.accept_shadows(shadows);
        self.counters.readback_bytes +=
            pixels.len() as u64 + depth_pixels.as_ref().map_or(0, |value| value.len() as u64);
        self.temporal.accept();
        self.accept_history(frame);
        self.profile.borrow_mut().status = "complete";
        Ok((pixels, depth_pixels))
    }
}

#[cfg(all(test, target_vendor = "apple"))]
mod metal_timeout_tests {
    use super::*;
    use objc2::runtime::ProtocolObject;
    use objc2_metal::{
        MTLCommandBuffer, MTLCommandQueue, MTLDevice, MTLPixelFormat, MTLSharedEvent,
        MTLStorageMode, MTLTextureDescriptor, MTLTextureUsage,
    };

    #[test]
    #[ignore = "requires a native Metal device"]
    fn resized_retained_graph_preserves_external_depth_on_rejection_and_retry() {
        use serde_json::json;
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let target = |renderer: &mut Renderer, size, format| {
            let state = renderer.state.as_mut().unwrap();
            state
                .resources
                .create_frame_target(&state.device, size, format)
                .unwrap()
        };
        let (scene_key, _) = target(&mut renderer, [16, 16], wgpu::TextureFormat::Rgba8UnormSrgb);
        let (output_key, _) = target(&mut renderer, [16, 16], wgpu::TextureFormat::Rgba8UnormSrgb);
        let key_json = |k: crate::resources::registry::ResourceKey| {
            json!([k.renderer, k.device_generation, k.slot, k.slot_generation])
        };
        let request = |command| {
            serde_json::to_vec(&json!({"version":1,"request":1,"command":command})).unwrap()
        };
        let shader: serde_json::Value = serde_json::from_slice(&renderer.shader_command(&request(json!({
            "operation":"compile","label":"resize-test","source":"@vertex fn vertex(@builtin(vertex_index) i:u32)->@builtin(position) vec4<f32>{let p=array<vec2<f32>,3>(vec2(-1.,-1.),vec2(3.,-1.),vec2(-1.,3.));return vec4(p[i],0.,1.);}@fragment fn fragment()->@location(0) vec4<f32>{return vec4(1.,0.,1.,1.);}"})), 256*1024).unwrap()).unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&renderer.graph_command(&request(json!({"operation":"compile","description":{
            "label":"resize-test","sceneColor":key_json(scene_key),"output":key_json(output_key),"inputs":[],
            "resources":[{"key":key_json(scene_key),"label":"scene"},{"key":key_json(output_key),"label":"output"}],
            "passes":[{"kind":"render","name":"paint","program":shader["result"]["key"],"bindings":[],"reads":[],"writes":[key_json(output_key)],"after":[],
                "vertexEntryPoint":"vertex","fragmentEntryPoint":"fragment","vertexCount":3,"instanceCount":1,"sampleCount":1,
                "color":{"key":key_json(output_key),"mipLevel":0,"load":"clear","store":"store","clear":[0,0,0,1]}}]}
        })),256*1024).unwrap()).unwrap();
        let fields: [u64; 4] = serde_json::from_value(reply["result"]["key"].clone())
            .unwrap_or_else(|_| panic!("{reply}"));
        let graph_key = crate::resources::registry::ResourceKey {
            renderer: fields[0],
            device_generation: fields[1],
            slot: fields[2],
            slot_generation: fields[3],
        };
        let mut frame: Frame = serde_json::from_value(json!({"version":1,"view_projection":glam::Mat4::IDENTITY.to_cols_array(),"background":[1,0,0],"light_direction":[0,0,1],"ambient":0.2,"geometries":[],"meshes":[]})).unwrap();
        frame.graph = Some(graph_key);
        frame.binary = Some(crate::scene_packet::ViewState {
            view: 77,
            revision: 1,
            retained: HashSet::new(),
            meshes: vec![],
            retained_textures: HashSet::new(),
            retained_instances: HashSet::new(),
            retained_poses: HashSet::new(),
        });
        renderer.render(&frame, 16, 16).unwrap();
        let mut upload = frame.clone();
        upload.graph = None;
        frame.binary.as_mut().unwrap().revision = 2;
        frame.admission = Some(Box::new(crate::scene_packet::Admission {
            view: 77,
            resources: vec![],
            backlog_bytes: 0,
            staged_bytes: 0,
            publish: false,
            upload: Some(Box::new(upload)),
        }));
        let (color_key, color) =
            target(&mut renderer, [24, 12], wgpu::TextureFormat::Rgba8UnormSrgb);
        let (depth_key, depth) = target(&mut renderer, [24, 12], wgpu::TextureFormat::Depth32Float);
        let before = renderer.resources.stats();
        let error = renderer
            .render_to_surface_with_depth(&frame, color, Some(depth), 24, 12)
            .unwrap_err();
        assert!(error.contains("internally owned depth"));
        assert!(renderer.failure.is_none());
        assert_eq!(renderer.views[&77].revision, 1);
        assert!(renderer.staging.is_empty());
        assert_eq!(renderer.resources.stats(), before);
        let (retry_color_key, color) =
            target(&mut renderer, [16, 16], wgpu::TextureFormat::Rgba8UnormSrgb);
        let (retry_depth_key, depth) =
            target(&mut renderer, [16, 16], wgpu::TextureFormat::Depth32Float);
        renderer
            .render_to_surface_with_depth(&frame, color, Some(depth), 16, 16)
            .unwrap();
        assert_eq!(renderer.views[&77].revision, 2);
        renderer.close_scene_view(77).unwrap();
        assert!(renderer.staging.is_empty());
        let state = renderer.state.as_mut().unwrap();
        state
            .graphs
            .release(
                &state.device,
                &mut state.resources,
                &mut state.shaders,
                graph_key,
            )
            .unwrap_or_else(|e| panic!("{e}"));
        state
            .resources
            .release_graph(
                &state.device,
                &[
                    scene_key,
                    output_key,
                    color_key,
                    depth_key,
                    retry_color_key,
                    retry_depth_key,
                ],
            )
            .unwrap();
        assert_eq!(state.resources.stats().0, 0);
    }

    #[test]
    #[ignore = "requires a native Metal device; blocks a private queue for three seconds"]
    fn gpu_timeout_retains_imported_texture_and_stops_new_submissions() {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let device = renderer.metal_device().unwrap();
        let descriptor = MTLTextureDescriptor::new();
        unsafe {
            descriptor.setWidth(16);
            descriptor.setHeight(16);
        }
        descriptor.setPixelFormat(MTLPixelFormat::BGRA8Unorm_sRGB);
        descriptor.setUsage(MTLTextureUsage::RenderTarget);
        descriptor.setStorageMode(MTLStorageMode::Shared);
        let texture = device.newTextureWithDescriptor(&descriptor).unwrap();
        let gate = device.newSharedEvent().unwrap();
        {
            // Exclusive renderer access: no wgpu submissions race this native wait.
            let queue = unsafe { renderer.queue.as_hal::<wgpu::hal::api::Metal>() }.unwrap();
            let blocker = queue.as_raw().commandBuffer().unwrap();
            blocker.encodeWaitForEvent_value(ProtocolObject::from_ref(&*gate), 1);
            blocker.commit();
        }
        let signal = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(3));
            gate.setSignaledValue(1);
        });
        let frame: Frame = serde_json::from_value(serde_json::json!({
            "version": 1, "view_projection": glam::Mat4::IDENTITY.to_cols_array(),
            "background": [0,0,0], "light_direction": [0,0,1], "ambient": 0.2,
            "geometries": [{"id":1,"positions":[[-0.8,-0.8,0.4],[0.8,-0.8,0.4],[0,0.8,0.4]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
            "meshes": [{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),"color":[1,0,0],"unlit":true}]
        }))
        .unwrap();
        let result = unsafe { renderer.render_to_metal(&frame, texture) };
        assert!(
            result.is_err(),
            "GPU wait must expire before the timer releases it"
        );
        assert_eq!(renderer.profile.borrow().status, "failed");
        assert!(renderer.profile.borrow().gpu_time_ns.is_none());
        assert!(
            renderer
                .profile
                .borrow()
                .passes
                .values()
                .all(|pass| pass.gpu_time_ns.is_none())
        );
        assert!(
            renderer.failed_surface.is_some(),
            "active imported storage stays owned"
        );
        let command = |renderer: &mut Renderer, operation: &str| {
            let mut command = serde_json::json!({"operation":operation});
            if operation == "inspectGpu" {
                command["allocation_limit"] = serde_json::json!(1);
            }
            if operation == "execute" {
                command["key"] = serde_json::json!([0, 0, 0, 0]);
            }
            let bytes = serde_json::to_vec(&serde_json::json!({"version":1,"request":1,
                "command":command}))
            .unwrap();
            serde_json::from_slice::<serde_json::Value>(
                &renderer.graph_command(&bytes, 256 * 1024).unwrap(),
            )
            .unwrap()
        };
        let profile = command(&mut renderer, "frameProfile");
        assert_eq!(profile["result"]["status"], "failed");
        assert_eq!(profile["result"]["drawCacheEntries"], 0);
        assert_eq!(profile["result"]["drawCacheUniformBytes"], 0);
        assert!(renderer.draw_cache.borrow().keys().is_empty());
        assert!(profile["result"]["gpuTimeNs"].is_null());
        assert_eq!(
            command(&mut renderer, "stats")["error"]["code"],
            "deviceFailed"
        );
        assert_eq!(
            command(&mut renderer, "execute")["error"]["code"],
            "deviceFailed"
        );
        assert_eq!(
            command(&mut renderer, "inspectGpu")["error"]["code"],
            "deviceFailed"
        );
        assert!(renderer.render(&frame, 16, 16).is_err());
        assert_eq!(renderer.counters().submitted_frames, 1);
        let closing = std::time::Instant::now();
        drop(renderer);
        assert!(
            closing.elapsed() < Duration::from_millis(250),
            "disposal must not wait for the blocked GPU queue"
        );
        assert_eq!(crate::fg_retiring_renderer_count(), 1);
        signal.join().unwrap();
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while crate::fg_retiring_renderer_count() != 0 && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(crate::fg_retiring_renderer_count(), 0);
    }
}

fn section_planes(mesh: &crate::scene::Mesh) -> [[f32; 4]; 6] {
    let mut planes = [[0.; 4]; 6];
    planes[..mesh.clipping_planes.len()].copy_from_slice(&mesh.clipping_planes);
    planes
}

#[cfg(test)]
mod readback_profile_tests {
    use super::*;
    #[test]
    #[ignore = "requires a native Metal, Vulkan or DX12 device"]
    fn terminal_callback_and_mapping_errors_never_leave_a_complete_profile() {
        for callback in [
            Err("readback callback failed: disconnected".to_string()),
            Ok(()),
        ] {
            let mut renderer = pollster::block_on(Renderer::new()).unwrap();
            let frame: Frame = serde_json::from_value(serde_json::json!({
                "version":1,"view_projection":glam::Mat4::IDENTITY.to_cols_array(),
                "background":[1,0,0],"light_direction":[0,0,1],"ambient":0.2,
                "geometries":[],"meshes":[]
            }))
            .unwrap();
            renderer.render(&frame, 8, 8).unwrap();
            let readback = renderer.targets.as_ref().unwrap().readback.clone();
            let stride = renderer.targets.as_ref().unwrap().stride;
            // The completed render already unmapped this real GPU buffer. Ok(())
            // therefore exercises a native get_mapped_range failure, independently
            // of the callback failure supplied by the other iteration.
            assert!(
                renderer
                    .copy_readback(&readback, 8, stride, 256, callback)
                    .is_err()
            );
            assert!(renderer.failure.is_some());
            assert_eq!(renderer.profile.borrow().status, "failed");
            let command = serde_json::to_vec(&serde_json::json!({"version":1,"request":1,
                "command":{"operation":"frameProfile"}}))
            .unwrap();
            let reply: serde_json::Value =
                serde_json::from_slice(&renderer.graph_command(&command, 256 * 1024).unwrap())
                    .unwrap();
            let profile = &reply["result"];
            assert_eq!(profile["status"], "failed");
            assert!(profile["gpuTimeNs"].is_null());
            assert_eq!(profile["gpuTimeSource"], "unavailable");
            assert!(
                profile["passes"]
                    .as_object()
                    .unwrap()
                    .values()
                    .all(|pass| pass["gpuTimeNs"].is_null())
            );
            assert_eq!(profile["submissionCount"], 1);
        }
    }
}
