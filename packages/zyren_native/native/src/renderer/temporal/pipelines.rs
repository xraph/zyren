use crate::scene::Mesh;
use std::collections::HashMap;
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub(super) struct MotionKey {
    pub deformed: bool,
    pub instanced: bool,
    pub textured: bool,
    pub colored: bool,
    side: u32,
    mirrored: bool,
    reactive: bool,
    depth_test: bool,
    reversed: bool,
}
impl MotionKey {
    pub fn new(mesh: &Mesh) -> Self {
        Self {
            deformed: mesh.pose != 0,
            instanced: mesh.instances != 0,
            textured: mesh.color_map.is_some(),
            colored: mesh.vertex_colors,
            side: mesh.side,
            mirrored: glam::Mat4::from_cols_array(&mesh.model).determinant() < 0.,
            reactive: mesh.alpha_mode == 2 || !mesh.writes_depth(),
            depth_test: mesh.depth_test,
            reversed: mesh.reversed_depth,
        }
    }
}
pub(super) struct Pipelines {
    pub uniform: wgpu::BindGroupLayout,
    pub texture: wgpu::BindGroupLayout,
    pub deformation: wgpu::BindGroupLayout,
    pub resolve_layout: wgpu::BindGroupLayout,
    pub resolve: wgpu::RenderPipeline,
    pub white: wgpu::TextureView,
    pub sampler: wgpu::Sampler,
    motion: HashMap<MotionKey, wgpu::RenderPipeline>,
}
impl Pipelines {
    pub fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Self {
        let uniform = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("temporal motion uniforms"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(416),
                },
                count: None,
            }],
        });
        let texture = super::super::textures::layout(device, 1);
        let deformation = super::super::deformation::layout(device);
        let mut entries: Vec<_> = (0..5)
            .map(|binding| wgpu::BindGroupLayoutEntry {
                binding,
                visibility: wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Texture {
                    sample_type: if binding == 2 {
                        wgpu::TextureSampleType::Depth
                    } else {
                        wgpu::TextureSampleType::Float { filterable: false }
                    },
                    view_dimension: wgpu::TextureViewDimension::D2,
                    multisampled: false,
                },
                count: None,
            })
            .collect();
        entries.push(wgpu::BindGroupLayoutEntry {
            binding: 5,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Buffer {
                ty: wgpu::BufferBindingType::Uniform,
                has_dynamic_offset: false,
                min_binding_size: wgpu::BufferSize::new(16),
            },
            count: None,
        });
        let resolve_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("temporal resolve inputs"),
            entries: &entries,
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("temporal resolve"),
            bind_group_layouts: &[Some(&resolve_layout)],
            ..Default::default()
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("temporal resolve"),
            source: wgpu::ShaderSource::Wgsl(include_str!("resolve.wgsl").into()),
        });
        let resolve = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("temporal resolve"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vertex"),
                compilation_options: Default::default(),
                buffers: &[],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fragment"),
                compilation_options: Default::default(),
                targets: &[
                    Some(wgpu::TextureFormat::Rgba16Float.into()),
                    Some(wgpu::TextureFormat::Rgba16Float.into()),
                    Some(wgpu::TextureFormat::R32Float.into()),
                ],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        let white = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("temporal alpha fallback"),
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
            white.as_image_copy(),
            &[255; 4],
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(4),
                rows_per_image: Some(1),
            },
            white.size(),
        );
        Self {
            uniform,
            texture,
            deformation,
            resolve_layout,
            resolve,
            white: white.create_view(&Default::default()),
            sampler: device.create_sampler(&Default::default()),
            motion: HashMap::new(),
        }
    }
    pub fn prepare(&mut self, device: &wgpu::Device, key: MotionKey) {
        if self.motion.contains_key(&key) {
            return;
        }
        let mut args = vec![
            "@location(0) position:vec3<f32>",
            "@location(1) previous:vec3<f32>",
            "@builtin(vertex_index) index:u32",
            "@builtin(instance_index) instance_index:u32",
        ];
        if key.textured {
            args.extend(["@location(2) uv0:vec2<f32>", "@location(3) uv1:vec2<f32>"]);
        }
        if key.instanced {
            args.push("instance:Instance");
        }
        if key.colored {
            args.push("@location(12) color:vec4<f32>");
        }
        let mut body = String::from("var p=position;var old=previous;\n");
        if key.deformed {
            body.push_str("p=deform_vertex(index,p,vec3(0.,0.,1.),vec4(1.,0.,0.,1.)).position;old=previous_deform_vertex(index,old,vec3(0.,0.,1.),vec4(1.,0.,0.,1.)).position;\n");
        }
        if key.instanced {
            body.push_str("let model=mat4x4(instance.current0,instance.current1,instance.current2,instance.current3);p=(model*vec4(p,1.)).xyz;old=(mat4x4(instance.previous0,instance.previous1,instance.previous2,instance.previous3)*vec4(old,1.)).xyz;\n");
        }
        body.push_str(&format!(
            "var result=vertex_data(p,old,{},{},instance_index);\n",
            if key.textured {
                "uv0,uv1"
            } else {
                "vec2(0.),vec2(0.)"
            },
            if key.colored { "color.a" } else { "1." }
        ));
        if key.instanced {
            body.push_str("result.alpha*=instance.color.a;result.valid*=select(0.,1.,all(instance.color==instance.previous_color));result.orientation=sign(determinant(mat3x3(model[0].xyz,model[1].xyz,model[2].xyz)));\n");
        }
        body.push_str("return result;");
        let vertex = format!(
            "@vertex fn vertex({}) -> Output {{ {} }}",
            args.join(","),
            body
        );
        let deformation = include_str!("../../deformation.wgsl");
        let prior = deformation
            .replace("deformation", "previous_deformation")
            .replace("DeformedVertex", "PreviousDeformedVertex")
            .replace("deform_vertex", "previous_deform_vertex")
            .replace("@group(2)", "@group(3)");
        let source = format!(
            "{}\n{}\n{}\n{}",
            include_str!("../coverage.wgsl"),
            deformation,
            prior,
            include_str!("motion.wgsl").replace("__VERTEX__", &vertex)
        );
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("temporal motion"),
            source: wgpu::ShaderSource::Wgsl(source.into()),
        });
        let mut groups = vec![Some(&self.uniform), Some(&self.texture)];
        if key.deformed {
            groups.extend([Some(&self.deformation), Some(&self.deformation)]);
        }
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("temporal motion"),
            bind_group_layouts: &groups,
            ..Default::default()
        });
        let current = wgpu::vertex_attr_array![0=>Float32x3];
        let previous = wgpu::vertex_attr_array![1=>Float32x3];
        let uv = wgpu::vertex_attr_array![2=>Float32x2,3=>Float32x2];
        let color = wgpu::vertex_attr_array![12=>Float32x4];
        let mut instances = wgpu::vertex_attr_array![4=>Float32x4,5=>Float32x4,6=>Float32x4,7=>Float32x4,13=>Float32x4];
        instances[4].offset = 112;
        let mut previous_instances = wgpu::vertex_attr_array![8=>Float32x4,9=>Float32x4,10=>Float32x4,11=>Float32x4,14=>Float32x4];
        previous_instances[4].offset = 112;
        let vertex_buffer = |stride, attributes| wgpu::VertexBufferLayout {
            array_stride: stride,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes,
        };
        let mut buffers = vec![vertex_buffer(24, &current), vertex_buffer(24, &previous)];
        if key.textured {
            buffers.push(vertex_buffer(16, &uv));
        }
        if key.colored {
            buffers.push(vertex_buffer(16, &color));
        }
        if key.instanced {
            for attributes in [&instances, &previous_instances] {
                buffers.push(wgpu::VertexBufferLayout {
                    array_stride: 128,
                    step_mode: wgpu::VertexStepMode::Instance,
                    attributes,
                });
            }
        }
        let buffers: Vec<_> = buffers.into_iter().map(Some).collect();
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("temporal motion"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vertex"),
                compilation_options: Default::default(),
                buffers: &buffers,
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fragment"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::TextureFormat::Rgba32Float.into())],
            }),
            primitive: wgpu::PrimitiveState {
                front_face: if key.mirrored {
                    wgpu::FrontFace::Cw
                } else {
                    wgpu::FrontFace::Ccw
                },
                cull_mode: if key.instanced {
                    None
                } else {
                    match key.side {
                        1 => Some(wgpu::Face::Back),
                        2 => Some(wgpu::Face::Front),
                        _ => None,
                    }
                },
                ..Default::default()
            },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: wgpu::TextureFormat::Depth32Float,
                depth_write_enabled: Some(false),
                depth_compare: Some(if !key.depth_test {
                    wgpu::CompareFunction::Always
                } else if key.reactive {
                    if key.reversed {
                        wgpu::CompareFunction::GreaterEqual
                    } else {
                        wgpu::CompareFunction::LessEqual
                    }
                } else {
                    wgpu::CompareFunction::Equal
                }),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        self.motion.insert(key, pipeline);
    }
    pub fn motion(&self, key: MotionKey) -> &wgpu::RenderPipeline {
        &self.motion[&key]
    }
}
