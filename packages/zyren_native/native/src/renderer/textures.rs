use super::*;
use crate::{
    resources::registry::ResourceKey,
    scene::{ColorMap, SceneTexture},
};

pub(super) struct GpuSceneTexture {
    pub key: ResourceKey,
    recipe: std::sync::Arc<SceneTexture>,
}
pub(super) fn layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("color map"),
        entries: &[
            wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            },
            wgpu::BindGroupLayoutEntry {
                binding: 1,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                count: None,
            },
        ],
    })
}
impl Renderer {
    pub(super) fn validate_textures(&self, frame: &Frame) -> Result<(usize, usize), String> {
        if frame.textures.len() > crate::scene::MAX_MESHES {
            return Err("too many texture uploads".into());
        }
        let mut added = HashMap::new();
        let mut bytes = 0;
        let mut count = 0;
        for image in &frame.textures {
            image.validate()?;
            if added.insert(image.id, image).is_some() {
                return Err("duplicate texture ID".into());
            }
            if let Some(old) = self.textures.get(&image.id) {
                if old.recipe.as_ref() != image {
                    return Err("texture ID refers to different immutable pixels".into());
                }
            } else {
                bytes += image.byte_length();
                count += 1;
            }
            if !frame
                .meshes
                .iter()
                .any(|mesh| mesh.material_maps().any(|map| map.texture == image.id))
            {
                return Err("uploaded texture must be used by a mesh".into());
            }
        }
        for mesh in &frame.meshes {
            for map in mesh.pbr_maps[..3].iter().flatten() {
                let image = added
                    .get(&map.texture)
                    .copied()
                    .or_else(|| self.textures.get(&map.texture).map(|v| v.recipe.as_ref()));
                if image.is_some_and(|image| image.format != 0) {
                    return Err("PBR data maps require linear RGBA8".into());
                }
            }
            for map in mesh.material_maps() {
                map.validate()?;
                if !added.contains_key(&map.texture) && !self.textures.contains_key(&map.texture) {
                    return Err("material refers to a missing texture".into());
                }
                let geometry = frame
                    .geometries
                    .iter()
                    .find(|g| g.id == mesh.geometry)
                    .or_else(|| {
                        self.geometries
                            .get(&mesh.geometry)
                            .map(|g| g.recipe.as_ref())
                    })
                    .ok_or("missing textured geometry")?;
                if (if map.uv_set == 0 {
                    &geometry.uv0
                } else {
                    &geometry.uv1
                })
                .is_empty()
                {
                    return Err("material requires a missing UV set".into());
                }
            }
        }
        Ok((bytes, count))
    }
    pub(super) fn upload_textures(&mut self, frame: &Frame) -> Result<(), String> {
        for image in &frame.textures {
            if !self.textures.contains_key(&image.id) {
                let state = self.state.as_mut().unwrap();
                let key = state
                    .resources
                    .insert_scene_texture(&state.device, &state.queue, image)
                    .map_err(|e| {
                        state.failure = Some(e.to_string());
                        e.to_string()
                    })?;
                state.textures.insert(
                    image.id,
                    GpuSceneTexture {
                        key,
                        recipe: std::sync::Arc::new(image.clone()),
                    },
                );
            }
        }
        Ok(())
    }
    pub(super) fn evict_textures(&mut self) -> Result<(), String> {
        let retained: HashSet<_> = self
            .views
            .values()
            .flat_map(|v| v.retained_textures.iter().copied())
            .collect();
        let removed: Vec<_> = self
            .textures
            .keys()
            .copied()
            .filter(|id| !retained.contains(id))
            .collect();
        for id in removed {
            let image = self.textures.remove(&id).unwrap();
            self.resources
                .release_scene_resource(image.key)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    pub(super) fn texture_binding(&self, map: &ColorMap) -> wgpu::BindGroup {
        let image = &self.textures[&map.texture];
        let view = self
            .resources
            .scene_texture(image.key)
            .create_view(&Default::default());
        let wrap = |value| match value {
            1 => wgpu::AddressMode::Repeat,
            2 => wgpu::AddressMode::MirrorRepeat,
            _ => wgpu::AddressMode::ClampToEdge,
        };
        let filter = |value| {
            if value == 0 {
                wgpu::FilterMode::Nearest
            } else {
                wgpu::FilterMode::Linear
            }
        };
        let sampler = self.device.create_sampler(&wgpu::SamplerDescriptor {
            address_mode_u: wrap(map.sampler[0]),
            address_mode_v: wrap(map.sampler[1]),
            min_filter: filter(map.sampler[2]),
            mag_filter: filter(map.sampler[3]),
            mipmap_filter: if map.sampler[4] == 0 {
                wgpu::MipmapFilterMode::Nearest
            } else {
                wgpu::MipmapFilterMode::Linear
            },
            ..Default::default()
        });
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("color map"),
            layout: &self.texture_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&sampler),
                },
            ],
        })
    }
}

pub(super) fn pbr_layout(device: &wgpu::Device) -> wgpu::BindGroupLayout {
    let entries: Vec<_> = (0..10)
        .map(|binding| wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: if binding % 2 == 0 {
                wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                }
            } else {
                wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering)
            },
            count: None,
        })
        .collect();
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("PBR maps"),
        entries: &entries,
    })
}
pub(super) fn white(device: &wgpu::Device, queue: &wgpu::Queue) -> wgpu::Texture {
    let texture = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("missing material map"),
        size: wgpu::Extent3d {
            width: 1,
            height: 1,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        texture.as_image_copy(),
        &[255; 4],
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(4),
            rows_per_image: Some(1),
        },
        texture.size(),
    );
    texture
}
impl Renderer {
    pub(super) fn pbr_texture_binding(&self, mesh: &crate::scene::Mesh) -> wgpu::BindGroup {
        let maps: Vec<_> = std::iter::once(mesh.color_map.as_ref())
            .chain(mesh.pbr_maps.iter().map(Option::as_ref))
            .collect();
        let views: Vec<_> = maps
            .iter()
            .map(|map| {
                map.map_or(&self.pbr_white, |m| {
                    self.resources.scene_texture(self.textures[&m.texture].key)
                })
                .create_view(&Default::default())
            })
            .collect();
        let samplers: Vec<_> = maps
            .iter()
            .map(|map| {
                let s = map.map_or([0, 0, 1, 1, 1], |m| m.sampler);
                let wrap = |v| match v {
                    1 => wgpu::AddressMode::Repeat,
                    2 => wgpu::AddressMode::MirrorRepeat,
                    _ => wgpu::AddressMode::ClampToEdge,
                };
                let filter = |v| {
                    if v == 0 {
                        wgpu::FilterMode::Nearest
                    } else {
                        wgpu::FilterMode::Linear
                    }
                };
                self.device.create_sampler(&wgpu::SamplerDescriptor {
                    address_mode_u: wrap(s[0]),
                    address_mode_v: wrap(s[1]),
                    min_filter: filter(s[2]),
                    mag_filter: filter(s[3]),
                    mipmap_filter: if s[4] == 0 {
                        wgpu::MipmapFilterMode::Nearest
                    } else {
                        wgpu::MipmapFilterMode::Linear
                    },
                    ..Default::default()
                })
            })
            .collect();
        let mut entries = Vec::new();
        for i in 0..5 {
            entries.push(wgpu::BindGroupEntry {
                binding: i as u32 * 2,
                resource: wgpu::BindingResource::TextureView(&views[i]),
            });
            entries.push(wgpu::BindGroupEntry {
                binding: i as u32 * 2 + 1,
                resource: wgpu::BindingResource::Sampler(&samplers[i]),
            });
        }
        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("PBR maps"),
            layout: &self.pbr_texture_layout,
            entries: &entries,
        })
    }
}
