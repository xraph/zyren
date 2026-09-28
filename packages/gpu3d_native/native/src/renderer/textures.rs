use super::*;
use crate::{
    resources::registry::ResourceKey,
    scene::{ColorMap, SceneTexture},
};

pub(super) struct GpuSceneTexture {
    pub key: ResourceKey,
    recipe: std::sync::Arc<SceneTexture>,
}
pub(super) fn layout(device: &wgpu::Device, maps: u32) -> wgpu::BindGroupLayout {
    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
        label: Some("color map"),
        entries: &(0..maps)
            .flat_map(|slot| {
                [
                    wgpu::BindGroupLayoutEntry {
                        binding: slot * 2,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: slot * 2 + 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ]
            })
            .collect::<Vec<_>>(),
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
                .any(|mesh| mesh.texture_maps().any(|map| map.texture == image.id))
            {
                return Err("uploaded texture must be used by a mesh".into());
            }
        }
        for mesh in &frame.meshes {
            for map in mesh.texture_maps() {
                map.validate()?;
                if !added.contains_key(&map.texture) && !self.textures.contains_key(&map.texture) {
                    return Err("material refers to a missing texture".into());
                }
                let image = added
                    .get(&map.texture)
                    .copied()
                    .or_else(|| self.textures.get(&map.texture).map(|t| t.recipe.as_ref()))
                    .ok_or("missing material image")?;
                if mesh.pbr.as_ref().is_some_and(|p| {
                    [
                        p.normal_map.as_ref(),
                        p.metallic_roughness_map.as_ref(),
                        p.occlusion_map.as_ref(),
                    ]
                    .into_iter()
                    .flatten()
                    .any(|data| data.texture == map.texture)
                }) && image.format != 0
                {
                    return Err(
                        "normal, metallic/roughness and occlusion maps require linear storage"
                            .into(),
                    );
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
    fn texture_parts(&self, map: &ColorMap) -> (wgpu::TextureView, wgpu::Sampler) {
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
        (view, sampler)
    }
    pub(super) fn texture_binding(&self, mesh: &crate::scene::Mesh) -> Option<wgpu::BindGroup> {
        let first = mesh.texture_maps().next()?;
        let maps: Vec<_> = match &mesh.pbr {
            Some(p) => [
                mesh.color_map.as_ref(),
                p.normal_map.as_ref(),
                p.metallic_roughness_map.as_ref(),
                p.occlusion_map.as_ref(),
                p.emissive_map.as_ref(),
            ]
            .into_iter()
            .map(|m| m.unwrap_or(first))
            .collect(),
            None => vec![first],
        };
        let parts: Vec<_> = maps.into_iter().map(|m| self.texture_parts(m)).collect();
        let entries: Vec<_> = parts
            .iter()
            .enumerate()
            .flat_map(|(i, (view, sampler))| {
                [
                    wgpu::BindGroupEntry {
                        binding: i as u32 * 2,
                        resource: wgpu::BindingResource::TextureView(view),
                    },
                    wgpu::BindGroupEntry {
                        binding: i as u32 * 2 + 1,
                        resource: wgpu::BindingResource::Sampler(sampler),
                    },
                ]
            })
            .collect();
        Some(self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("material maps"),
            layout: if mesh.pbr.is_some() {
                &self.standard_texture_layout
            } else {
                &self.texture_layout
            },
            entries: &entries,
        }))
    }
}
