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
        mask: u16,
        frame: &wgpu::BindGroupLayout,
        standard: &wgpu::BindGroupLayout,
        deformation: &wgpu::BindGroupLayout,
    ) -> Self {
        let entries: Vec<_> = (0..8)
            .filter(|i| mask & (1 << i) != 0)
            .flat_map(|i| {
                [
                    wgpu::BindGroupLayoutEntry {
                        binding: i * 2,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: i * 2 + 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ]
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
            source: wgpu::ShaderSource::Wgsl(super::pipelines::shader_source(mask).into()),
        });
        Self {
            shader,
            plain: layout(None),
            deformed: layout(Some(deformation)),
            maps,
        }
    }
}
pub(super) fn shader(mask: u16) -> String {
    let mut declarations = String::new();
    let mut body = String::from("var surface=original;\n");
    for i in 0..8 {
        if mask & (1 << i) == 0 {
            continue;
        }
        declarations.push_str(&format!("@group(3) @binding({}) var physical_map_{i}: texture_2d<f32>;\n@group(3) @binding({}) var physical_sampler_{i}: sampler;\n", i*2, i*2+1));
        body.push_str(&format!("let uv_{i}=select(input.uv0,input.uv1,(uniforms.pbr_maps.w & {}u)!=0u);\nlet sample_{i}=textureSample(physical_map_{i},physical_sampler_{i},uv_{i});\n",1<<i));
        body.push_str(match i {
            0 => "surface.physical[0].z*=sample_0.r;\n",
            1 => "surface.physical[0].w*=sample_1.g;\n",
            2 => "surface.coat_normal=mapped_normal(input,uv_2,sample_2.rgb,uniforms.physical[3].z);\n",
            3 => "surface.physical[2]=vec4(surface.physical[2].rgb*sample_3.rgb,surface.physical[2].w);\n",
            4 => "surface.physical[1].w*=sample_4.a;\n",
            5 => "surface.physical[0].y*=sample_5.a;\n",
            6 => "surface.physical[1]=vec4(surface.physical[1].rgb*sample_6.rgb,surface.physical[1].w);\n",
            7 => "let direction=sample_7.rg*2.-vec2(1.);\nsurface.physical[2].w*=sample_7.b;\nsurface.physical[3].x+=select(0.,atan2(direction.y,direction.x),dot(direction,direction)>1e-12);\n",
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
        let mask = material.physical_map_mask();
        if mask == 0 {
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
                [
                    wgpu::BindGroupEntry {
                        binding: *i as u32 * 2,
                        resource: wgpu::BindingResource::TextureView(view),
                    },
                    wgpu::BindGroupEntry {
                        binding: *i as u32 * 2 + 1,
                        resource: wgpu::BindingResource::Sampler(sampler),
                    },
                ]
            })
            .collect();
        Some(self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("physical layer maps"),
            layout: self.pipelines.physical_layout(mask),
            entries: &entries,
        }))
    }
}
