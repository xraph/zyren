use super::Renderer;
use crate::scene::Mesh;

pub(super) struct Variant {
    pub shader: wgpu::ShaderModule,
    pub maps: wgpu::BindGroupLayout,
    pub plain: wgpu::PipelineLayout,
    pub deformed: wgpu::PipelineLayout,
}
impl Variant {
    pub fn new(
        device: &wgpu::Device,
        key: u64,
        frame: &wgpu::BindGroupLayout,
        standard: &wgpu::BindGroupLayout,
        deformation: &wgpu::BindGroupLayout,
    ) -> Self {
        let entries: Vec<_> = (0..12)
            .filter(|i| sampler_slot(key, *i).is_some())
            .flat_map(|i| {
                let mut entries = vec![wgpu::BindGroupLayoutEntry {
                    binding: i * 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                }];
                if sampler_slot(key, i) == Some(i) {
                    entries.push(wgpu::BindGroupLayoutEntry {
                        binding: i * 2 + 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    });
                }
                entries
            })
            .collect();
        let maps = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("physical layer maps"),
            entries: &entries,
        });
        let layout = |deformation| {
            device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("physical layer maps"),
                bind_group_layouts: &[Some(frame), Some(standard), deformation, Some(&maps)],
                ..Default::default()
            })
        };
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("mapped physical material"),
            source: wgpu::ShaderSource::Wgsl(super::pipelines::shader_source(key).into()),
        });
        Self {
            shader,
            plain: layout(None),
            deformed: layout(Some(deformation)),
            maps,
        }
    }
}
pub(super) fn shader(key: u64) -> String {
    let mut declarations = String::new();
    let mut body = String::from("var surface=original;\n");
    for i in 0..12 {
        let Some(sampler) = sampler_slot(key, i) else {
            continue;
        };
        declarations.push_str(&format!(
            "@group(3) @binding({}) var physical_map_{i}: texture_2d<f32>;\n",
            i * 2
        ));
        if sampler == i {
            declarations.push_str(&format!(
                "@group(3) @binding({}) var physical_sampler_{i}: sampler;\n",
                i * 2 + 1
            ));
        }
        body.push_str(&format!("let uv_{i}=select(input.uv0,input.uv1,(uniforms.pbr_maps.w & {}u)!=0u);\nlet sample_{i}=textureSample(physical_map_{i},physical_sampler_{sampler},uv_{i});\n",1<<i));
        body.push_str(match i {
            0 => "surface.physical[0].z*=sample_0.r;\n",
            1 => "surface.physical[0].w*=sample_1.g;\n",
            2 => "var coat_input=input;\n\
                  let base_normal_uv=(uniforms.pbr_maps.y>>1u)&1u;\n\
                  let coat_normal_uv=(uniforms.pbr_maps.w>>2u)&1u;\n\
                  if ((uniforms.pbr_maps.x&2u)!=0u && base_normal_uv!=coat_normal_uv) {coat_input.tangent=vec4(0.);}\n\
                  surface.coat_normal=mapped_normal(coat_input,uv_2,sample_2.rgb,vec2(uniforms.physical[3].z));\n",
            3 => "surface.physical[2]=vec4(surface.physical[2].rgb*sample_3.rgb,surface.physical[2].w);\n",
            4 => "surface.physical[1].w*=sample_4.a;\n",
            5 => "surface.physical[0].y*=sample_5.a;\n",
            6 => "surface.physical[1]=vec4(surface.physical[1].rgb*sample_6.rgb,surface.physical[1].w);\n",
            7 => "let direction=sample_7.rg*2.-vec2(1.);\nsurface.physical[2].w*=sample_7.b;\nsurface.physical[3].x+=select(0.,atan2(direction.y,direction.x),dot(direction,direction)>1e-12);\n",
            8 => "surface.transmission[0].x*=sample_8.r;\n",
            9 => "surface.transmission[0].y*=sample_9.g;\n",
            10 => "surface.optical[0].x*=sample_10.r;\n",
            11 => "surface.optical[0].w=mix(surface.optical[0].z,surface.optical[0].w,sample_11.g);\n",
            _ => unreachable!(),
        });
    }
    format!(
        "{declarations}\nfn physical_surface(input:VertexOutput, original:StandardSurface) -> StandardSurface {{\n{body}return surface;\n}}"
    )
}
impl Renderer {
    pub(super) fn physical_texture_binding(&self, mesh: &Mesh) -> Option<wgpu::BindGroup> {
        let material = mesh.pbr.as_ref()?;
        let key = binding_key(material);
        if key == 0 {
            return None;
        }
        let parts: Vec<_> = material
            .physical_maps
            .iter()
            .enumerate()
            .filter_map(|(i, map)| map.as_ref().map(|map| (i, self.texture_parts(map))))
            .collect();
        let entries: Vec<_> = parts
            .iter()
            .flat_map(|(i, (view, sampler))| {
                let mut entries = vec![wgpu::BindGroupEntry {
                    binding: *i as u32 * 2,
                    resource: wgpu::BindingResource::TextureView(view),
                }];
                if sampler_slot(key, *i as u32) == Some(*i as u32) {
                    entries.push(wgpu::BindGroupEntry {
                        binding: *i as u32 * 2 + 1,
                        resource: wgpu::BindingResource::Sampler(sampler),
                    });
                }
                entries
            })
            .collect();
        Some(self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("physical layer maps"),
            layout: self.pipelines.physical_layout(key),
            entries: &entries,
        }))
    }
}

// Encode sampler equivalence, independent of texture identity and sampler values.
pub(super) fn binding_key(material: &crate::lighting::StandardMaterial) -> u64 {
    material
        .physical_maps
        .iter()
        .enumerate()
        .fold(0, |key, (i, map)| {
            let Some(map) = map else {
                return key;
            };
            let first = material.physical_maps[..i]
                .iter()
                .position(|m| m.as_ref().is_some_and(|m| m.sampler == map.sampler))
                .unwrap_or(i);
            key | ((first as u64 + 1) << (i * 4))
        })
}
fn sampler_slot(key: u64, i: u32) -> Option<u32> {
    let value = ((key >> (i * 4)) & 15) as u32;
    value.checked_sub(1)
}
pub(super) fn binding_counts(key: u64) -> (u32, u32) {
    (
        (0..12).filter(|i| sampler_slot(key, *i).is_some()).count() as u32,
        (0..12)
            .filter(|i| sampler_slot(key, *i) == Some(*i))
            .count() as u32,
    )
}

impl Renderer {
    pub(super) fn check_physical_bindings(
        &self,
        frame: &crate::scene::Frame,
    ) -> Result<(), String> {
        for mesh in &frame.meshes {
            let Some(material) = &mesh.pbr else {
                continue;
            };
            let (textures, samplers) = binding_counts(binding_key(material));
            if textures + 13 > self.device.limits().max_sampled_textures_per_shader_stage
                || samplers + 8 > self.device.limits().max_samplers_per_shader_stage
            {
                return Err(
                    "Physical maps exceed this adapter's texture or sampler binding limit".into(),
                );
            }
        }
        Ok(())
    }
}
