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
            if !frame.meshes.iter().any(|mesh| {
                mesh.color_map
                    .as_ref()
                    .is_some_and(|map| map.texture == image.id)
            }) {
                return Err("uploaded texture must be used by a mesh".into());
            }
        }
        for mesh in &frame.meshes {
            if let Some(map) = &mesh.color_map {
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
