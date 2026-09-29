mod area_lights;
mod environment;
use std::{
    collections::{HashMap, HashSet},
    sync::mpsc,
    time::Duration,
};

use bytemuck::{Pod, Zeroable};
use glam::Mat4;
use wgpu::util::DeviceExt;

use crate::scene::{Frame, pixel_len};
mod composition;
mod deformation;
mod draw_order;
mod instances;
mod materials;
mod pipelines;
mod shadows;
mod temporal;
mod textures;
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
}

struct GpuGeometry {
    deformation_bounds: crate::deformation::SourceBounds,
    key: crate::resources::registry::ResourceKey,
    recipe: std::sync::Arc<crate::scene::Geometry>,
    center: glam::Vec3,
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
}

#[derive(Clone, Copy, Debug, Default)]
pub struct RenderCounters {
    pub submitted_frames: u64,
    pub readback_bytes: u64,
}
#[cfg(any(target_vendor = "apple", target_os = "android"))]
struct DepthTarget {
    width: u32,
    height: u32,
    _texture: wgpu::Texture,
    view: wgpu::TextureView,
}

struct Submission {
    index: wgpu::SubmissionIndex,
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
    texture_layout: wgpu::BindGroupLayout,
    standard_texture_layout: wgpu::BindGroupLayout,
    textures: HashMap<u32, textures::GpuSceneTexture>,
    #[cfg(any(target_vendor = "apple", target_os = "android"))]
    surface_depth: Option<DepthTarget>,
    #[cfg(any(target_vendor = "apple", target_os = "android"))]
    failed_surface: Option<wgpu::Texture>,
    #[cfg(target_vendor = "apple")]
    pub(crate) drawable_owner: Option<crate::interop::metal::DrawableOwner>,
    pub(crate) failure: Option<String>,
    counters: RenderCounters,
    last_scene_draws: std::cell::Cell<u64>,
    layout: wgpu::BindGroupLayout,
    pbr_layout: wgpu::BindGroupLayout,
    environment_defaults: environment::Defaults,
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
    targets: Option<Targets>,
    temporal: temporal::System,
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
        if let Some(state) = self.state.take() {
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
        let info = adapter.get_info();
        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("flutter_gpu3d"),
                required_limits: wgpu::Limits {
                    max_texture_dimension_2d: crate::scene::MAX_DIMENSION,
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
            ]
            .concat(),
        });
        let environment_defaults = environment::Defaults::new(&device);
        let area_tables = area_lights::Tables::new(&device, &queue);
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
                texture_layout,
                standard_texture_layout,
                pbr_layout,
                environment_defaults,
                area_tables,
                shadows,
                textures: HashMap::new(),
                #[cfg(any(target_vendor = "apple", target_os = "android"))]
                surface_depth: None,
                #[cfg(any(target_vendor = "apple", target_os = "android"))]
                failed_surface: None,
                #[cfg(target_vendor = "apple")]
                drawable_owner: None,
                failure: None,
                counters: RenderCounters::default(),
                last_scene_draws: std::cell::Cell::new(0),
                layout,
                geometries: HashMap::new(),
                instances: HashMap::new(),
                poses: HashMap::new(),
                deformation_layout,
                resources: crate::resources::ResourceStore::default(),
                shaders: crate::shaders::ShaderStore::default(),
                graphs: crate::render_graph::GraphStore::default(),
                views: HashMap::new(),
                targets: None,
                temporal: temporal::System::default(),
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
        let state = self.state.as_mut().unwrap();
        state.graphs.command(
            crate::render_graph::GraphContext {
                shadow_stats,
                temporal_stats,
                mesh_layout: &state.layout,
                deformation_layout: &state.deformation_layout,
                device: &state.device,
                queue: &state.queue,
                resources: &mut state.resources,
                shaders: &mut state.shaders,
                failure: &mut state.failure,
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
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
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
        Ok(frame)
    }
    fn decode_plain_scene(&self, bytes: &[u8]) -> Result<Frame, String> {
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
            serde_json::from_slice(bytes).map_err(|error| format!("invalid scene: {error}"))
        }
    }
    pub fn scene_draw_stats(&self) -> (u64, usize) {
        (self.last_scene_draws.get(), self.pipelines.len())
    }
    pub fn scene_resource_stats(&self) -> (u64, u64) {
        self.resources.stats()
    }
    pub fn close_scene_view(&mut self, view: u64) -> Result<(), String> {
        self.views.remove(&view);
        self.shadows.remove(view);
        self.temporal.remove(view);
        self.evict_geometry()
    }
    fn evict_geometry(&mut self) -> Result<(), String> {
        let retained: HashSet<u32> = self
            .views
            .values()
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
        state.resources.collect(&state.device).map_err(|e| {
            state.failure = Some(e.to_string());
            e.to_string()
        })
    }
    fn prepare_scene(&mut self, frame: &Frame) -> Result<(), String> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
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
                !self.geometries.contains_key(&patch.id)
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
            })
            .map(|p| (p.id, p.base))
            .collect();
        let bytes: usize = frame
            .geometries
            .iter()
            .filter(|g| !self.geometries.contains_key(&g.id) && !reusable.contains_key(&g.id))
            .map(|g| g.byte_length())
            .sum();
        self.resources
            .check_scene_capacity(
                (bytes + texture_bytes + instance_bytes + pose_bytes) as u64,
                frame
                    .geometries
                    .iter()
                    .filter(|g| {
                        !self.geometries.contains_key(&g.id) && !reusable.contains_key(&g.id)
                    })
                    .count()
                    + texture_count
                    + instance_count
                    + pose_count,
            )
            .map_err(|e| e.to_string())?;
        // Preflight all CPU validation before any existing ownership changes.
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
                        deformation_bounds: crate::deformation::SourceBounds::new(geometry),
                    },
                );
            }
        }
        self.upload_textures(frame)?;
        self.upload_instances(frame, &reusable_instances)?;
        self.upload_poses(frame)?;
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
        self.views.insert(view, state);
        self.evict_geometry()
    }

    fn prepare_pipelines(
        &mut self,
        frame: &Frame,
        format: wgpu::TextureFormat,
    ) -> Result<(), String> {
        let state = self.state.as_mut().unwrap();
        let geometries = &state.geometries;
        state
            .pipelines
            .prepare(&state.device, frame, format, |id| {
                !geometries[&id].recipe.tangents.is_empty()
            })
            .inspect_err(|error| {
                state.failure = Some(error.clone());
            })
    }

    fn encode_scene(
        &self,
        frame: &Frame,
        attachments: (
            &wgpu::TextureView,
            Option<&wgpu::TextureView>,
            &wgpu::TextureView,
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
        let (color_view, resolve_target, depth_view) = attachments;
        let (materials, graph, environment, shadows) = composition;
        let vp = Mat4::from_cols_array(&self.temporal.vp(frame));
        let lighting = frame.meshes.iter().any(|m| m.pbr.is_some()).then(|| {
            self.device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("punctual lights"),
                    contents: bytemuck::bytes_of(&crate::lighting::LightingUniform::capture(
                        &frame.lights,
                        &frame.hemispheres,
                        &frame.areas,
                    )),
                    usage: wgpu::BufferUsages::UNIFORM,
                })
        });
        let bindings: Vec<_> = frame
            .meshes
            .iter()
            .map(|mesh| {
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
                let uniforms = Uniforms {
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
                            0.,
                        ]
                    }),
                    pbr_params: mesh.pbr.as_ref().map_or([0.; 4], |p| {
                        [
                            p.metallic,
                            p.roughness,
                            if mesh.receive_shadow { 1. } else { 0. },
                            0.,
                        ]
                    }),
                    emissive: mesh.pbr.as_ref().map_or([0.; 4], |p| {
                        [p.emissive[0], p.emissive[1], p.emissive[2], 0.]
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
                        if mesh.instances != 0 {
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
                let buffer = self
                    .device
                    .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                        label: None,
                        contents: bytemuck::bytes_of(&uniforms),
                        usage: wgpu::BufferUsages::UNIFORM,
                    });
                let mut entries = vec![wgpu::BindGroupEntry {
                    binding: 0,
                    resource: buffer.as_entire_binding(),
                }];
                if mesh.pbr.is_some() {
                    entries.push(wgpu::BindGroupEntry {
                        binding: 1,
                        resource: lighting.as_ref().unwrap().as_entire_binding(),
                    });
                    entries.extend(environment.entries(&self.environment_defaults));
                    entries.extend(shadows.entries(&self.shadows));
                    entries.extend(self.area_tables.entries());
                }
                self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: None,
                    layout: if mesh.pbr.is_some() {
                        &self.pbr_layout
                    } else {
                        &self.layout
                    },
                    entries: &entries,
                })
            })
            .collect();
        let texture_bindings: Vec<_> = frame
            .meshes
            .iter()
            .map(|mesh| self.texture_binding(mesh))
            .collect();
        let mut encoder = self.device.create_command_encoder(&Default::default());
        if let Some(graph) = graph {
            graph.encode_before(&mut encoder);
        }
        shadows.encode(self, frame, &mut encoder);
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("native frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: color_view,
                    resolve_target,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: frame.background[0] * f64::from(frame.background_alpha),
                            g: frame.background[1] * f64::from(frame.background_alpha),
                            b: frame.background[2] * f64::from(frame.background_alpha),
                            a: f64::from(frame.background_alpha),
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: depth_view,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: if frame.temporal.is_some() {
                            wgpu::StoreOp::Store
                        } else {
                            wgpu::StoreOp::Discard
                        },
                    }),
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            let draws = draw_order::sorted(
                frame,
                |mesh| {
                    if mesh.pose == 0 {
                        self.geometries[&mesh.geometry].center
                    } else {
                        self.poses[&mesh.pose].center
                    }
                },
                |id, index| {
                    Mat4::from_cols_array(&self.instances[&id].recipe.transforms[index as usize])
                },
            );
            self.last_scene_draws.set(draws.len() as u64);
            for draw in draws {
                let index = draw.mesh;
                let mesh = &frame.meshes[index];
                let binding = &bindings[index];
                let texture_binding = &texture_bindings[index];
                let geometry = &self.geometries[&mesh.geometry];
                if let Some(material) = &materials[index] {
                    material.bind(&mut pass);
                } else {
                    pass.set_pipeline(self.pipelines.get(pipelines::PipelineKey::new(
                        format,
                        mesh,
                        !geometry.recipe.tangents.is_empty(),
                        frame.sample_count(),
                    )));
                }
                pass.set_bind_group(0, binding, &[]);
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
                    pass.set_bind_group(1, binding, &[]);
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
                if mesh.instances != 0 {
                    let textured = mesh.texture_maps().next().is_some();
                    let tangent = (textured || mesh.anisotropic())
                        && mesh.pbr.is_some()
                        && !geometry.recipe.tangents.is_empty();
                    let buffer = self
                        .resources
                        .graph_buffer(self.instances[&mesh.instances].key)
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
                    pass.set_bind_group(2, &self.poses[&mesh.pose].binding, &[]);
                }
                pass.draw_indexed(0..count, 0, draw.instances);
            }
        }
        encoder
    }

    fn submit(
        &mut self,
        encoder: wgpu::CommandEncoder,
        graph: Option<&crate::render_graph::FrameGraph>,
        materials: &[Option<crate::render_graph::PreparedMaterial>],
        environment: &environment::PreparedEnvironment,
    ) -> Result<Submission, String> {
        let index = self.queue.submit([encoder.finish()]);
        let keys: Vec<_> = self
            .geometries
            .values()
            .map(|g| g.key)
            .chain(self.textures.values().map(|t| t.key))
            .chain(self.instances.values().map(|i| i.key))
            .chain(self.poses.values().map(|p| p.key))
            .chain(environment.resources.iter().copied())
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
            self.failure = Some(error.to_string());
            return Err(error.to_string());
        }
        self.counters.submitted_frames += 1;
        #[cfg(target_vendor = "apple")]
        let metal = if self.backend == wgpu::Backend::Metal {
            match crate::interop::metal::MetalCompletion::capture(&self.queue) {
                Ok(completion) => Some(completion),
                Err(error) => {
                    self.failure = Some(error.clone());
                    return Err(error);
                }
            }
        } else {
            None
        };
        Ok(Submission {
            index,
            #[cfg(target_vendor = "apple")]
            metal,
        })
    }

    fn wait_for_submission(&mut self, submission: Submission) -> Result<(), String> {
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
            Some(completion) => completion.check(),
            None => Ok(()),
        });
        if result.is_ok() {
            self.resources.scene_completed();
        }
        result.map_err(|error| {
            let message = format!("GPU completion failed; recreate this renderer: {error}");
            self.failure = Some(message.clone());
            message
        })
    }

    #[cfg(any(target_vendor = "apple", target_os = "android"))]
    pub(crate) fn render_to_surface(
        &mut self,
        frame: &Frame,
        texture: wgpu::Texture,
        width: u32,
        height: u32,
    ) -> Result<(), String> {
        pixel_len(width, height)?;
        self.check_shadows(frame)?;
        self.check_temporal(frame, [width, height])?;
        let graph = self.resolve_frame_graph(frame, width, height)?;
        let environment = self.prepare_environment(frame, graph.as_ref())?;
        let materials = self.prepare_materials(frame, texture.format(), graph.as_ref())?;
        let scene_format = composition::scene_format(frame, texture.format(), graph.as_ref())?;
        // Attachment rejection must precede scene revisions and reusable-buffer edits.
        self.prepare_frame_targets(
            frame,
            texture.format(),
            [width, height],
            graph.as_ref(),
            true,
        )?;
        self.prepare_scene(frame)?;
        self.prepare_pipelines(frame, scene_format)?;
        let shadows = self.prepare_shadows(frame)?;
        self.prepare_temporal(frame, [width, height])?;
        if self
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
        let encoder = self.encode_frame(
            frame,
            &texture.create_view(&Default::default()),
            &self.surface_depth.as_ref().unwrap().view,
            texture.format(),
            [texture.width(), texture.height()],
            (graph.as_ref(), &materials, true, &environment, &shadows),
        );
        let result = self
            .submit(encoder, graph.as_ref(), &materials, &environment)
            .and_then(|submission| self.wait_for_submission(submission));
        if let Err(error) = result {
            // Stop future submissions and keep the imported resource owned.
            self.failed_surface = Some(texture);
            return Err(error);
        }
        self.accept_shadows(shadows);
        self.temporal.accept();
        Ok(())
    }

    pub fn render(&mut self, frame: &Frame, width: u32, height: u32) -> Result<Vec<u8>, String> {
        let len = pixel_len(width, height)?;
        self.check_shadows(frame)?;
        self.check_temporal(frame, [width, height])?;
        let graph = self.resolve_frame_graph(frame, width, height)?;
        let environment = self.prepare_environment(frame, graph.as_ref())?;
        let materials =
            self.prepare_materials(frame, wgpu::TextureFormat::Rgba8UnormSrgb, graph.as_ref())?;
        let scene_format =
            composition::scene_format(frame, wgpu::TextureFormat::Rgba8UnormSrgb, graph.as_ref())?;
        self.prepare_frame_targets(
            frame,
            wgpu::TextureFormat::Rgba8UnormSrgb,
            [width, height],
            graph.as_ref(),
            false,
        )?;
        self.prepare_scene(frame)?;
        self.prepare_pipelines(frame, scene_format)?;
        let shadows = self.prepare_shadows(frame)?;
        self.prepare_temporal(frame, [width, height])?;
        self.resize(width, height);
        let target = self.targets.as_ref().unwrap();
        let mut encoder = self.encode_frame(
            frame,
            &target.color_view,
            &target.depth_view,
            wgpu::TextureFormat::Rgba8UnormSrgb,
            [width, height],
            (graph.as_ref(), &materials, false, &environment, &shadows),
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
        let readback = target.readback.clone();
        let stride = target.stride;
        let submission = self.submit(encoder, graph.as_ref(), &materials, &environment)?;
        let slice = readback.slice(..);
        let (sender, receiver) = mpsc::sync_channel(1);
        slice.map_async(wgpu::MapMode::Read, move |result| {
            let _ = sender.send(result);
        });
        self.wait_for_submission(submission)?;
        self.accept_shadows(shadows);
        let mapped_result = receiver
            .recv_timeout(Duration::from_secs(1))
            .map_err(|error| format!("readback callback failed: {error}"))
            .and_then(|result| result.map_err(|error| format!("readback failed: {error}")));
        if let Err(error) = mapped_result {
            self.failure = Some(error.clone());
            return Err(error);
        }
        let mapped = slice.get_mapped_range().map_err(|e| e.to_string())?;
        let mut pixels = Vec::with_capacity(len);
        for row in mapped.chunks_exact(stride as usize) {
            pixels.extend_from_slice(&row[..width as usize * 4]);
        }
        drop(mapped);
        readback.unmap();
        self.counters.readback_bytes += pixels.len() as u64;
        self.temporal.accept();
        Ok(pixels)
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
            "geometries": [], "meshes": []
        }))
        .unwrap();
        let result = unsafe { renderer.render_to_metal(&frame, texture) };
        assert!(
            result.is_err(),
            "GPU wait must expire before the timer releases it"
        );
        assert!(
            renderer.failed_surface.is_some(),
            "active imported storage stays owned"
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
