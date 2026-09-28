use super::*;
use crate::resources::registry::ResourceKey;

pub(super) fn key(v: [u64; 4]) -> ResourceKey {
    ResourceKey {
        renderer: v[0],
        device_generation: v[1],
        slot: v[2],
        slot_generation: v[3],
    }
}
pub(super) struct Environment {
    pub layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    black: [wgpu::Texture; 3],
}
impl Environment {
    pub fn new(device: &wgpu::Device) -> Self {
        let mut entries = Vec::new();
        for binding in 0..3 {
            entries.push(wgpu::BindGroupLayoutEntry {
                binding,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: wgpu::TextureSampleType::Float { filterable: true },
                    view_dimension: if binding == 1 {
                        wgpu::TextureViewDimension::D3
                    } else {
                        wgpu::TextureViewDimension::D2
                    },
                    multisampled: false,
                },
                count: None,
            });
        }
        entries.push(wgpu::BindGroupLayoutEntry {
            binding: 3,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
            count: None,
        });
        entries.push(wgpu::BindGroupLayoutEntry {
            binding: 4,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: wgpu::BufferSize::new(16),
            },
            count: None,
        });
        Self {
            layout: device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                label: Some("environment"),
                entries: &entries,
            }),
            sampler: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("environment"),
                address_mode_u: wgpu::AddressMode::Repeat,
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            }),
            black: std::array::from_fn(|i| {
                device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("empty environment"),
                    size: wgpu::Extent3d {
                        width: 1,
                        height: 1,
                        depth_or_array_layers: if i == 1 { 2 } else { 1 },
                    },
                    mip_level_count: 1,
                    sample_count: 1,
                    dimension: if i == 1 {
                        wgpu::TextureDimension::D3
                    } else {
                        wgpu::TextureDimension::D2
                    },
                    format: wgpu::TextureFormat::Rgba16Float,
                    usage: wgpu::TextureUsages::TEXTURE_BINDING,
                    view_formats: &[],
                })
            }),
        }
    }
    pub fn textures(
        &self,
        frame: &Frame,
        store: &crate::resources::ResourceStore,
    ) -> Result<[wgpu::Texture; 3], String> {
        let Some(environment) = &frame.settings.environment else {
            return Ok(self.black.clone());
        };
        let mut textures = Vec::new();
        for (i, id) in environment.keys.iter().enumerate() {
            let texture = store.graph_texture(key(*id)).map_err(|e| e.to_string())?;
            if texture.format() != wgpu::TextureFormat::Rgba16Float
                || texture.mip_level_count() != 1
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
                return Err("Invalid environment texture layout".into());
            }
            textures.push(texture);
        }
        Ok(textures.try_into().ok().unwrap())
    }
    pub fn binding(
        &self,
        device: &wgpu::Device,
        frame: &Frame,
        store: &crate::resources::ResourceStore,
    ) -> wgpu::BindGroup {
        let textures = self.textures(frame, store).expect("validated environment");
        let views = textures.map(|t| t.create_view(&Default::default()));
        let params = frame
            .settings
            .environment
            .as_ref()
            .map_or([0.; 4], |e| [e.intensity, e.rotation, 1., 0.]);
        let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("environment parameters"),
            contents: bytemuck::cast_slice(&params),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let mut entries: Vec<_> = views
            .iter()
            .enumerate()
            .map(|(i, v)| wgpu::BindGroupEntry {
                binding: i as u32,
                resource: wgpu::BindingResource::TextureView(v),
            })
            .collect();
        entries.push(wgpu::BindGroupEntry {
            binding: 3,
            resource: wgpu::BindingResource::Sampler(&self.sampler),
        });
        entries.push(wgpu::BindGroupEntry {
            binding: 4,
            resource: buffer.as_entire_binding(),
        });
        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("environment"),
            layout: &self.layout,
            entries: &entries,
        })
    }
}
