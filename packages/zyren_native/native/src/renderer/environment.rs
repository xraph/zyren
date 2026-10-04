use super::Renderer;
use crate::{render_graph::FrameGraph, resources::registry::ResourceKey, scene::Frame};

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Uniform {
    params: [f32; 4],
    rotation: [f32; 4],
}

pub(super) const UNIFORM_BYTES: usize = std::mem::size_of::<Uniform>();

pub(super) struct Defaults {
    black: wgpu::Texture,
    volume: wgpu::Texture,
    environment_sampler: wgpu::Sampler,
    brdf_sampler: wgpu::Sampler,
}
impl Defaults {
    pub fn new(device: &wgpu::Device) -> Self {
        let black = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("empty environment"),
            size: wgpu::Extent3d {
                width: 1,
                height: 1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba16Float,
            usage: wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
        let descriptor = wgpu::SamplerDescriptor {
            label: Some("environment filtering"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            mipmap_filter: wgpu::MipmapFilterMode::Linear,
            ..Default::default()
        };
        Self {
            volume: device.create_texture(&wgpu::TextureDescriptor {
                label: Some("empty volume environment"),
                size: wgpu::Extent3d {
                    width: 1,
                    height: 1,
                    depth_or_array_layers: 2,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D3,
                format: wgpu::TextureFormat::Rgba16Float,
                usage: wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            }),
            black,
            environment_sampler: device.create_sampler(&wgpu::SamplerDescriptor {
                address_mode_u: wgpu::AddressMode::Repeat,
                ..descriptor.clone()
            }),
            brdf_sampler: device.create_sampler(&descriptor),
        }
    }
}

pub(super) struct EnvironmentInput {
    locals: Vec<(Vec<usize>, EnvironmentInput)>,
    resources: Vec<ResourceKey>,
    textures: [wgpu::Texture; 3],
    volume: wgpu::Texture,
    uniform: Uniform,
}
impl EnvironmentInput {
    pub fn prepare(self, renderer: &Renderer, frame: &Frame) -> PreparedEnvironment {
        self.prepare_slot(renderer, frame, 0)
    }
    fn prepare_slot(self, renderer: &Renderer, frame: &Frame, slot: usize) -> PreparedEnvironment {
        let volume = renderer.draw_cache.borrow_mut().texture(&self.volume);
        let views = self
            .textures
            .map(|texture| renderer.draw_cache.borrow_mut().texture(&texture));
        let mut resources = self.resources;
        let mut locals = Vec::new();
        for (slot, (meshes, input)) in self.locals.into_iter().enumerate() {
            let prepared = input.prepare_slot(renderer, frame, slot + 1);
            resources.extend(prepared.resources.iter().copied());
            locals.push((meshes, prepared));
        }
        PreparedEnvironment {
            locals,
            resources,
            volume,
            views,
            uniform: frame.meshes.iter().any(|m| m.pbr.is_some()).then(|| {
                renderer.draw_uniform(
                    super::draw_cache::UniformKey::Environment(slot),
                    bytemuck::bytes_of(&self.uniform),
                )
            }),
        }
    }
}
pub(super) struct PreparedEnvironment {
    locals: Vec<(Vec<usize>, PreparedEnvironment)>,
    pub resources: Vec<ResourceKey>,
    views: [wgpu::TextureView; 3],
    volume: wgpu::TextureView,
    uniform: Option<wgpu::Buffer>,
}
impl PreparedEnvironment {
    pub fn for_mesh(&self, index: usize) -> &Self {
        self.locals
            .iter()
            .find(|(meshes, _)| meshes.contains(&index))
            .map_or(self, |(_, e)| e)
    }
    pub fn entries<'a>(&'a self, defaults: &'a Defaults) -> [wgpu::BindGroupEntry<'a>; 7] {
        [
            wgpu::BindGroupEntry {
                binding: 15,
                resource: wgpu::BindingResource::TextureView(&self.volume),
            },
            wgpu::BindGroupEntry {
                binding: 2,
                resource: self
                    .uniform
                    .as_ref()
                    .expect("PBR environment prepared")
                    .as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 3,
                resource: wgpu::BindingResource::TextureView(&self.views[0]),
            },
            wgpu::BindGroupEntry {
                binding: 4,
                resource: wgpu::BindingResource::TextureView(&self.views[1]),
            },
            wgpu::BindGroupEntry {
                binding: 5,
                resource: wgpu::BindingResource::TextureView(&self.views[2]),
            },
            wgpu::BindGroupEntry {
                binding: 6,
                resource: wgpu::BindingResource::Sampler(&defaults.environment_sampler),
            },
            wgpu::BindGroupEntry {
                binding: 7,
                resource: wgpu::BindingResource::Sampler(&defaults.brdf_sampler),
            },
        ]
    }
}

pub(super) fn layout_entries() -> Vec<wgpu::BindGroupLayoutEntry> {
    let mut entries = vec![wgpu::BindGroupLayoutEntry {
        binding: 2,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: wgpu::BufferSize::new(std::mem::size_of::<Uniform>() as u64),
        },
        count: None,
    }];
    for binding in 3..6 {
        entries.push(wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type: wgpu::TextureSampleType::Float { filterable: true },
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        });
    }
    entries.push(wgpu::BindGroupLayoutEntry {
        binding: 15,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Float { filterable: true },
            view_dimension: wgpu::TextureViewDimension::D3,
            multisampled: false,
        },
        count: None,
    });
    for binding in 6..8 {
        entries.push(wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
            count: None,
        });
    }
    entries
}

impl Renderer {
    pub(super) fn prepare_environment(
        &self,
        frame: &Frame,
        graph: Option<&FrameGraph>,
    ) -> Result<EnvironmentInput, String> {
        let mut resources = vec![];
        let mut uniform = Uniform {
            params: [0.; 4],
            rotation: [0., 0., 0., 1.],
        };
        let mut textures =
            std::array::from_fn::<_, 3, _>(|_| self.environment_defaults.black.clone());
        if frame.meshes.iter().any(|m| m.pbr.is_some()) {
            if let Some(table) = &self.energy_lut.table {
                textures[2] = table.texture.clone();
                resources.push(table.key);
            }
        }
        let mut volume = self.environment_defaults.volume.clone();
        if frame.environment.is_some() && frame.settings.environment.is_some() {
            return Err("Only one environment may illuminate a frame".into());
        }
        if let Some(environment) = &frame.environment {
            environment.validate()?;
            for (i, key) in environment.textures.iter().enumerate() {
                if graph.is_some_and(|graph| *key == graph.scene_resource) {
                    return Err("Environment cannot sample the scene color attachment".into());
                }
                let texture = self
                    .resources
                    .graph_texture(*key)
                    .map_err(|e| e.to_string())?;
                let width = texture.width();
                let height = texture.height();
                let max_width = [256, 1024, 512][i];
                let mips = if i == 1 {
                    width.ilog2().saturating_sub(2)
                } else {
                    1
                };
                if texture.format() != wgpu::TextureFormat::Rgba16Float
                    || texture.sample_count() != 1
                    || !texture
                        .usage()
                        .contains(wgpu::TextureUsages::TEXTURE_BINDING)
                    || !(16..=max_width).contains(&width)
                    || !width.is_power_of_two()
                    || height != if i == 2 { width } else { width / 2 }
                    || texture.mip_level_count() != mips
                {
                    return Err(
                        "Environment textures do not match the RGBA16F lighting profile".into(),
                    );
                }
                textures[i] = texture;
                resources.push(*key);
            }
            uniform.params = [
                environment.intensity,
                (textures[1].mip_level_count() - 1) as f32,
                0.,
                0.,
            ];
            uniform.rotation = environment.rotation;
        }
        if let Some(environment) = &frame.settings.environment {
            for (i, key) in environment.keys.iter().enumerate() {
                let key = crate::resources::registry::ResourceKey {
                    renderer: key[0],
                    device_generation: key[1],
                    slot: key[2],
                    slot_generation: key[3],
                };
                if graph.is_some_and(|g| key == g.scene_resource) {
                    return Err("Environment cannot sample the scene attachment".into());
                }
                let texture = self
                    .resources
                    .graph_texture(key)
                    .map_err(|e| e.to_string())?;
                if texture.format() != wgpu::TextureFormat::Rgba16Float
                    || texture.mip_level_count() != 1
                    || texture.sample_count() != 1
                    || texture.dimension()
                        != if i == 1 {
                            wgpu::TextureDimension::D3
                        } else {
                            wgpu::TextureDimension::D2
                        }
                    || !texture
                        .usage()
                        .contains(wgpu::TextureUsages::TEXTURE_BINDING)
                    || (i == 1 && texture.depth_or_array_layers() < 2)
                {
                    return Err("Invalid volume environment texture layout".into());
                }
                resources.push(key);
                if i == 1 {
                    volume = texture;
                } else {
                    textures[i] = texture;
                }
            }
            uniform.params = [
                environment.intensity,
                (volume.depth_or_array_layers() - 1) as f32,
                1.,
                0.,
            ];
            uniform.rotation = glam::Quat::from_rotation_y(environment.rotation).to_array();
        }
        let mut locals = Vec::new();
        for local in &frame.settings.local_environments {
            if local
                .meshes
                .iter()
                .any(|i| *i >= frame.meshes.len() || frame.meshes[*i].pbr.is_none())
            {
                return Err("Local environment requires valid PBR mesh indices".into());
            }
            let mut selected = frame.clone();
            selected.environment = Some(local.environment());
            selected.settings.environment = None;
            selected.settings.local_environments.clear();
            locals.push((
                local.meshes.clone(),
                self.prepare_environment(&selected, graph)?,
            ));
        }
        Ok(EnvironmentInput {
            locals,
            resources,
            textures,
            volume,
            uniform,
        })
    }
}
