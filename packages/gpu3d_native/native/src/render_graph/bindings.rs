use super::{GraphError, descriptor::*, key};
use crate::resources::ResourceStore;
use std::{
    collections::{HashMap, HashSet},
    num::NonZeroU64,
};

pub enum BoundResource {
    Buffer(wgpu::Buffer, u64, NonZeroU64),
    Texture(wgpu::TextureView),
    Sampler(wgpu::Sampler),
}
impl BoundResource {
    pub fn binding(&self) -> wgpu::BindingResource<'_> {
        match self {
            Self::Buffer(buffer, offset, size) => {
                wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                    buffer,
                    offset: *offset,
                    size: Some(*size),
                })
            }
            Self::Texture(view) => wgpu::BindingResource::TextureView(view),
            Self::Sampler(sampler) => wgpu::BindingResource::Sampler(sampler),
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct LayoutKey {
    pub group: u32,
    pub binding: u32,
    pub stages: u32,
    pub kind: BindingKind,
    pub size: u64,
    pub filtering: bool,
}
pub struct Bindings {
    pub layouts: Vec<Vec<wgpu::BindGroupLayoutEntry>>,
    pub resources: Vec<Vec<(u32, BoundResource)>>,
    pub keys: Vec<LayoutKey>,
    pub reads: HashSet<Key>,
    pub writes: HashSet<Key>,
    uses: HashMap<Key, bool>,
}
impl Bindings {
    pub fn use_resource(&mut self, key: Key, read: bool, write: bool) -> Result<(), GraphError> {
        if self
            .uses
            .get(&key)
            .is_some_and(|previous_write| *previous_write || write)
        {
            return Err(GraphError::new(
                "aliasConflict",
                "Writable resource occupies another slot in this pass",
            ));
        }
        self.uses.insert(key, write);
        if read {
            self.reads.insert(key);
        }
        if write {
            self.writes.insert(key);
        }
        Ok(())
    }
}
fn invalid(message: &str) -> GraphError {
    GraphError::new("invalidBinding", message)
}
pub fn prepare(
    device: &wgpu::Device,
    store: &ResourceStore,
    pass: &Pass,
) -> Result<Bindings, GraphError> {
    if pass.bindings.len() > 64 || pass.bindings.iter().any(|b| b.group >= 4) {
        return Err(invalid("Too many bindings"));
    }
    let groups = pass.bindings.iter().map(|b| b.group + 1).max().unwrap_or(0);
    if groups > 4 {
        return Err(invalid("Bind group exceeds the portable limit"));
    }
    let mut result = Bindings {
        layouts: (0..groups).map(|_| vec![]).collect(),
        resources: (0..groups).map(|_| vec![]).collect(),
        keys: vec![],
        reads: HashSet::new(),
        writes: HashSet::new(),
        uses: HashMap::new(),
    };
    let mut slots = HashSet::new();
    for binding in &pass.bindings {
        if binding.binding >= 16 || !slots.insert((binding.group, binding.binding)) {
            return Err(invalid("Invalid or duplicate binding slot"));
        }
        let mut visibility = wgpu::ShaderStages::empty();
        for stage in &binding.stages {
            let flag = match stage {
                0 => wgpu::ShaderStages::VERTEX,
                1 => wgpu::ShaderStages::FRAGMENT,
                2 => wgpu::ShaderStages::COMPUTE,
                _ => return Err(invalid("Unknown shader stage")),
            };
            if visibility.contains(flag) {
                return Err(invalid("Duplicate shader stage"));
            }
            visibility |= flag;
        }
        let allowed = if pass.kind == Kind::Compute {
            wgpu::ShaderStages::COMPUTE
        } else {
            wgpu::ShaderStages::VERTEX_FRAGMENT
        };
        if visibility.is_empty() || !allowed.contains(visibility) {
            return Err(invalid("Binding visibility disagrees with pass stages"));
        }
        let mut layout_key = LayoutKey {
            group: binding.group,
            binding: binding.binding,
            stages: visibility.bits(),
            kind: binding.kind,
            size: 0,
            filtering: false,
        };
        let (ty, resource) = match binding.kind {
            BindingKind::Uniform | BindingKind::StorageRead | BindingKind::StorageReadWrite => {
                if binding.mip_level.is_some()
                    || binding.mip_levels.is_some()
                    || binding.sampler.is_some()
                {
                    return Err(invalid("Unexpected buffer binding fields"));
                }
                let id = binding.key.ok_or_else(|| invalid("Buffer key missing"))?;
                let buffer = store.graph_buffer(key(id))?;
                let offset = binding
                    .offset
                    .ok_or_else(|| invalid("Buffer offset missing"))?;
                let size = binding
                    .size
                    .and_then(NonZeroU64::new)
                    .ok_or_else(|| invalid("Buffer size missing or zero"))?;
                let uniform = binding.kind == BindingKind::Uniform;
                let alignment = if uniform {
                    device.limits().min_uniform_buffer_offset_alignment
                } else {
                    device.limits().min_storage_buffer_offset_alignment
                };
                let maximum = if uniform {
                    device.limits().max_uniform_buffer_binding_size
                } else {
                    device.limits().max_storage_buffer_binding_size
                };
                let usage = if uniform {
                    wgpu::BufferUsages::UNIFORM
                } else {
                    wgpu::BufferUsages::STORAGE
                };
                if !buffer.usage().contains(usage)
                    || !offset.is_multiple_of(alignment as u64)
                    || !size.get().is_multiple_of(4)
                    || size.get() > maximum
                    || offset
                        .checked_add(size.get())
                        .is_none_or(|end| end > buffer.size())
                {
                    return Err(invalid("Buffer usage, alignment or range is invalid"));
                }
                result.use_resource(id, true, binding.kind == BindingKind::StorageReadWrite)?;
                layout_key.size = size.get();
                let ty = if uniform {
                    wgpu::BufferBindingType::Uniform
                } else {
                    wgpu::BufferBindingType::Storage {
                        read_only: binding.kind == BindingKind::StorageRead,
                    }
                };
                (
                    wgpu::BindingType::Buffer {
                        ty,
                        has_dynamic_offset: false,
                        min_binding_size: Some(size),
                    },
                    BoundResource::Buffer(buffer, offset, size),
                )
            }
            BindingKind::Sampled | BindingKind::StorageTexture => {
                if binding.offset.is_some() || binding.size.is_some() || binding.sampler.is_some() {
                    return Err(invalid("Unexpected texture binding fields"));
                }
                let id = binding.key.ok_or_else(|| invalid("Texture key missing"))?;
                let texture = store.graph_texture(key(id))?;
                let level = binding
                    .mip_level
                    .ok_or_else(|| invalid("Mip level missing"))?;
                let levels = binding
                    .mip_levels
                    .ok_or_else(|| invalid("Mip count missing"))?;
                let storage = binding.kind == BindingKind::StorageTexture;
                let usage = if storage {
                    wgpu::TextureUsages::STORAGE_BINDING
                } else {
                    wgpu::TextureUsages::TEXTURE_BINDING
                };
                if !texture.usage().contains(usage)
                    || levels == 0
                    || level
                        .checked_add(levels)
                        .is_none_or(|end| end > texture.mip_level_count())
                    || (storage
                        && (!matches!(
                            texture.format(),
                            wgpu::TextureFormat::Rgba8Unorm | wgpu::TextureFormat::Rgba16Float
                        ) || levels != 1))
                {
                    return Err(invalid(
                        "Texture usage, mip range or storage format is invalid",
                    ));
                }
                result.use_resource(id, !storage, storage)?;
                let view = texture.create_view(&wgpu::TextureViewDescriptor {
                    base_mip_level: level,
                    mip_level_count: Some(levels),
                    usage: Some(usage),
                    ..Default::default()
                });
                let ty = if storage {
                    wgpu::BindingType::StorageTexture {
                        access: wgpu::StorageTextureAccess::WriteOnly,
                        format: texture.format(),
                        view_dimension: wgpu::TextureViewDimension::D2,
                    }
                } else {
                    wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    }
                };
                (ty, BoundResource::Texture(view))
            }
            BindingKind::Sampler => {
                if binding.key.is_some()
                    || binding.offset.is_some()
                    || binding.size.is_some()
                    || binding.mip_level.is_some()
                    || binding.mip_levels.is_some()
                {
                    return Err(invalid("Unexpected sampler binding fields"));
                }
                let data = binding
                    .sampler
                    .ok_or_else(|| invalid("Sampler descriptor missing"))?;
                if data[0] > 2 || data[1] > 2 || data[2..].iter().any(|v| *v > 1) {
                    return Err(invalid("Invalid sampler descriptor"));
                }
                let wrap = |index: u32| {
                    [
                        wgpu::AddressMode::ClampToEdge,
                        wgpu::AddressMode::Repeat,
                        wgpu::AddressMode::MirrorRepeat,
                    ][index as usize]
                };
                let filter = |index: u32| {
                    if index == 0 {
                        wgpu::FilterMode::Nearest
                    } else {
                        wgpu::FilterMode::Linear
                    }
                };
                layout_key.filtering = data[2..].contains(&1);
                let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
                    address_mode_u: wrap(data[0]),
                    address_mode_v: wrap(data[1]),
                    min_filter: filter(data[2]),
                    mag_filter: filter(data[3]),
                    mipmap_filter: if data[4] == 0 {
                        wgpu::MipmapFilterMode::Nearest
                    } else {
                        wgpu::MipmapFilterMode::Linear
                    },
                    ..Default::default()
                });
                (
                    wgpu::BindingType::Sampler(if layout_key.filtering {
                        wgpu::SamplerBindingType::Filtering
                    } else {
                        wgpu::SamplerBindingType::NonFiltering
                    }),
                    BoundResource::Sampler(sampler),
                )
            }
        };
        result.layouts[binding.group as usize].push(wgpu::BindGroupLayoutEntry {
            binding: binding.binding,
            visibility,
            ty,
            count: None,
        });
        result.resources[binding.group as usize].push((binding.binding, resource));
        result.keys.push(layout_key);
    }
    result.keys.sort_by_key(|key| (key.group, key.binding));
    Ok(result)
}
