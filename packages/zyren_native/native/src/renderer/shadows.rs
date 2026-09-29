use super::*;
use crate::shadows::{ATLAS_BYTES, ATLAS_SIZE, AtlasRect, MAX_BYTES, MAX_VIEWS, ShadowFrame};

#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ViewUniform {
    projection: [f32; 16],
    rect: [f32; 4],
    params: [f32; 4],
    interval: [f32; 4],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct ShadowUniform {
    forward: [f32; 4],
    lights: [[u32; 4]; crate::shadows::MAX_SHADOW_LIGHTS],
    views: [ViewUniform; MAX_VIEWS],
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
struct DepthUniform {
    mvp: [f32; 16],
    params: [f32; 4],
    side: [f32; 4],
}
#[derive(Clone, PartialEq)]
struct Caster {
    geometry: u32,
    instances: u32,
    pose: u32,
    instance_count: u32,
    key: crate::resources::registry::ResourceKey,
    model: [f32; 16],
    side: u32,
    alpha_mode: u32,
    vertex_colors: bool,
    opacity: f32,
    cutoff: f32,
    map: Option<crate::scene::ColorMap>,
}
#[derive(Clone, PartialEq)]
struct Signature {
    frame: ShadowFrame,
    casters: Vec<Caster>,
}
struct Atlas {
    texture: wgpu::Texture,
    signature: Option<Signature>,
}
#[derive(Clone, Copy, Default, Debug)]
pub struct ShadowStats {
    pub atlas_count: usize,
    pub resident_bytes: u64,
    pub rendered_views: u64,
    pub reused_frames: u64,
}
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct PipelineKey {
    textured: bool,
    colored: bool,
    instanced: bool,
    deformed: bool,
    mirrored: bool,
    side: u32,
}
impl PipelineKey {
    fn new(mesh: &crate::scene::Mesh) -> Self {
        Self {
            instanced: mesh.instances != 0,
            deformed: mesh.pose != 0,
            textured: mesh.alpha_mode == 1 && mesh.color_map.is_some(),
            colored: mesh.alpha_mode == 1 && mesh.vertex_colors,
            mirrored: Mat4::from_cols_array(&mesh.model).determinant() < 0.,
            side: mesh.side,
        }
    }
}
pub(super) struct ShadowSystem {
    atlases: HashMap<u64, Atlas>,
    empty: wgpu::Texture,
    sampler: wgpu::Sampler,
    layout: wgpu::BindGroupLayout,
    plain: wgpu::PipelineLayout,
    deformed_plain: wgpu::PipelineLayout,
    deformed_textured: wgpu::PipelineLayout,
    textured: wgpu::PipelineLayout,
    shader: wgpu::ShaderModule,
    pipelines: HashMap<PipelineKey, wgpu::RenderPipeline>,
    rendered_views: u64,
    reused_frames: u64,
}
fn depth_texture(device: &wgpu::Device, size: u32) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some("shadow depth atlas"),
        size: wgpu::Extent3d {
            width: size,
            height: size,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Depth32Float,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
        view_formats: &[],
    })
}
pub(super) fn layout_entries() -> Vec<wgpu::BindGroupLayoutEntry> {
    [
        wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: wgpu::BufferSize::new(std::mem::size_of::<ShadowUniform>() as u64),
        },
        wgpu::BindingType::Texture {
            sample_type: wgpu::TextureSampleType::Depth,
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Comparison),
    ]
    .into_iter()
    .enumerate()
    .map(|(i, ty)| wgpu::BindGroupLayoutEntry {
        binding: 8 + i as u32,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty,
        count: None,
    })
    .collect()
}
impl ShadowSystem {
    pub fn new(
        device: &wgpu::Device,
        texture_layout: &wgpu::BindGroupLayout,
        deformation_layout: &wgpu::BindGroupLayout,
    ) -> Self {
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("shadow caster"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(
                        std::mem::size_of::<DepthUniform>() as u64
                    ),
                },
                count: None,
            }],
        });
        Self {
            atlases: HashMap::new(),
            empty: depth_texture(device, 1),
            sampler: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("shadow comparison"),
                compare: Some(wgpu::CompareFunction::LessEqual),
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            }),
            deformed_plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("deformed triangles"),
                bind_group_layouts: &[Some(&layout), None, Some(deformation_layout)],
                ..Default::default()
            }),
            deformed_textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("deformed triangles"),
                bind_group_layouts: &[
                    Some(&layout),
                    Some(texture_layout),
                    Some(deformation_layout),
                ],
                ..Default::default()
            }),
            plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("shadow caster"),
                bind_group_layouts: &[Some(&layout)],
                ..Default::default()
            }),
            textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("masked shadow caster"),
                bind_group_layouts: &[Some(&layout), Some(texture_layout)],
                ..Default::default()
            }),
            shader: device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("shadow depth"),
                source: wgpu::ShaderSource::Wgsl(
                    concat!(
                        include_str!("shadow_depth.wgsl"),
                        "\n",
                        include_str!("../deformation.wgsl"),
                        "\n",
                        include_str!("deformation_depth.wgsl")
                    )
                    .into(),
                ),
            }),
            layout,
            pipelines: HashMap::new(),
            rendered_views: 0,
            reused_frames: 0,
        }
    }
    pub fn remove(&mut self, view: u64) {
        self.atlases.remove(&view);
    }
    fn check(&self, frame: &Frame) -> Result<(), String> {
        frame
            .shadows
            .validate_with_areas(&frame.lights, &frame.areas)?;
        for mesh in &frame.meshes {
            if mesh.receive_shadow && mesh.pbr.is_none() {
                return Err("Shadow receivers require standard materials".into());
            }
            if mesh.cast_shadow
                && (mesh.primitive_kind != 0 || mesh.alpha_mode == 2 || mesh.shader.is_some())
            {
                return Err("Shadow casters require built-in opaque or masked triangles".into());
            }
        }
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        if !frame.shadows.views.is_empty()
            && !self.atlases.contains_key(&view)
            && (self.atlases.len() as u64 + 1) * ATLAS_BYTES > MAX_BYTES
        {
            return Err("Shadow atlases exceed the device's 64 MiB budget".into());
        }
        if frame.shadows.views.len() * frame.meshes.iter().filter(|m| m.cast_shadow).count() > 65536
        {
            return Err("Shadow frame exceeds 65536 caster draws".into());
        }
        Ok(())
    }
    fn pipeline(&self, device: &wgpu::Device, key: PipelineKey) -> wgpu::RenderPipeline {
        let instance_attributes = wgpu::vertex_attr_array![6=>Float32x4,7=>Float32x4,8=>Float32x4,9=>Float32x4,10=>Float32x4,11=>Float32x4,12=>Float32x4,13=>Float32x3];
        let attributes = wgpu::vertex_attr_array![0 => Float32x3];
        let color_attributes = wgpu::vertex_attr_array![5=>Float32x4];
        let uv_attributes = wgpu::vertex_attr_array![2 => Float32x2, 3 => Float32x2];
        let mut buffers = vec![Some(wgpu::VertexBufferLayout {
            array_stride: 24,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &attributes,
        })];
        if key.textured {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: 16,
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: &uv_attributes,
            }));
        }
        if key.colored {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: 16,
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: &color_attributes,
            }));
        }
        if key.instanced {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: crate::instances::INSTANCE_STRIDE as u64,
                step_mode: wgpu::VertexStepMode::Instance,
                attributes: &instance_attributes,
            }));
        }
        let vertex_entry = if key.instanced {
            match (key.textured, key.colored) {
                (true, true) => "vs_instance_depth_textured_colored",
                (true, false) => "vs_instance_depth_textured",
                (false, true) => "vs_instance_depth_colored",
                (false, false) => "vs_instance_depth",
            }
        } else if key.textured {
            if key.colored {
                "vs_depth_textured_colored"
            } else {
                "vs_depth_textured"
            }
        } else {
            if key.colored {
                "vs_depth_colored"
            } else {
                "vs_depth"
            }
        };
        let vertex_entry = if key.deformed {
            format!("deformed_{vertex_entry}")
        } else {
            vertex_entry.to_owned()
        };
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("shadow depth"),
            layout: Some(if key.deformed {
                if key.textured {
                    &self.deformed_textured
                } else {
                    &self.deformed_plain
                }
            } else if key.textured {
                &self.textured
            } else {
                &self.plain
            }),
            vertex: wgpu::VertexState {
                module: &self.shader,
                entry_point: Some(&vertex_entry),
                compilation_options: Default::default(),
                buffers: &buffers,
            },
            fragment: Some(wgpu::FragmentState {
                module: &self.shader,
                entry_point: Some(if key.textured {
                    "fs_depth_textured"
                } else {
                    "fs_depth"
                }),
                compilation_options: Default::default(),
                targets: &[],
            }),
            primitive: wgpu::PrimitiveState {
                front_face: if key.mirrored {
                    wgpu::FrontFace::Cw
                } else {
                    wgpu::FrontFace::Ccw
                },
                cull_mode: match if key.instanced { 0 } else { key.side } {
                    1 => Some(wgpu::Face::Back),
                    2 => Some(wgpu::Face::Front),
                    _ => None,
                },
                ..Default::default()
            },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: wgpu::TextureFormat::Depth32Float,
                depth_write_enabled: Some(true),
                depth_compare: Some(wgpu::CompareFunction::LessEqual),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        })
    }
}
struct CasterDraw {
    mesh: usize,
    binding: wgpu::BindGroup,
    alpha: Option<wgpu::BindGroup>,
}
pub(super) struct PreparedShadows {
    view: u64,
    uniform: wgpu::Buffer,
    atlas: wgpu::TextureView,
    rects: Vec<AtlasRect>,
    draws: Vec<Vec<CasterDraw>>,
    signature: Option<Signature>,
}
impl PreparedShadows {
    pub fn entries<'a>(&'a self, system: &'a ShadowSystem) -> [wgpu::BindGroupEntry<'a>; 3] {
        [
            wgpu::BindGroupEntry {
                binding: 8,
                resource: self.uniform.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 9,
                resource: wgpu::BindingResource::TextureView(&self.atlas),
            },
            wgpu::BindGroupEntry {
                binding: 10,
                resource: wgpu::BindingResource::Sampler(&system.sampler),
            },
        ]
    }
    pub fn encode(&self, renderer: &Renderer, frame: &Frame, encoder: &mut wgpu::CommandEncoder) {
        if self.signature.is_none() {
            return;
        }
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("shadow atlas"),
            color_attachments: &[],
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                view: &self.atlas,
                depth_ops: Some(wgpu::Operations {
                    load: wgpu::LoadOp::Clear(1.),
                    store: wgpu::StoreOp::Store,
                }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        for (rect, draws) in self.rects.iter().zip(&self.draws) {
            pass.set_viewport(
                rect.x as f32,
                rect.y as f32,
                rect.size as f32,
                rect.size as f32,
                0.,
                1.,
            );
            pass.set_scissor_rect(rect.x, rect.y, rect.size, rect.size);
            for draw in draws {
                let mesh = &frame.meshes[draw.mesh];
                pass.set_pipeline(&renderer.shadows.pipelines[&PipelineKey::new(mesh)]);
                pass.set_bind_group(0, &draw.binding, &[]);
                let geometry = &renderer.geometries[&mesh.geometry];
                let (vertices, indices, count, uv, format) =
                    renderer.resources.geometry(geometry.key);
                pass.set_vertex_buffer(0, vertices.slice(..));
                let pipeline = PipelineKey::new(mesh);
                if pipeline.colored {
                    pass.set_vertex_buffer(
                        1 + u32::from(pipeline.textured),
                        renderer
                            .resources
                            .geometry_colors(geometry.key)
                            .expect("validated shadow colors")
                            .slice(..),
                    );
                }

                if let Some(alpha) = &draw.alpha {
                    pass.set_bind_group(1, alpha, &[]);
                    pass.set_vertex_buffer(1, uv.expect("validated shadow UV buffer").slice(..));
                }
                pass.set_index_buffer(indices.slice(..), format);
                if mesh.instances != 0 {
                    let buffer = renderer
                        .resources
                        .graph_buffer(renderer.instances[&mesh.instances].key)
                        .expect("validated shadow instance buffer");
                    pass.set_vertex_buffer(
                        1 + u32::from(pipeline.textured) + u32::from(pipeline.colored),
                        buffer.slice(..),
                    );
                }
                if mesh.pose != 0 {
                    pass.set_bind_group(2, &renderer.poses[&mesh.pose].binding, &[]);
                }
                pass.draw_indexed(0..count, 0, 0..mesh.instance_count);
            }
        }
    }
}
impl Renderer {
    pub fn shadow_stats(&self) -> ShadowStats {
        ShadowStats {
            atlas_count: self.shadows.atlases.len(),
            resident_bytes: self.shadows.atlases.len() as u64 * ATLAS_BYTES,
            rendered_views: self.shadows.rendered_views,
            reused_frames: self.shadows.reused_frames,
        }
    }
    pub(super) fn check_shadows(&self, frame: &Frame) -> Result<(), String> {
        self.shadows.check(frame)
    }
    pub(super) fn prepare_shadows(&mut self, frame: &Frame) -> Result<PreparedShadows, String> {
        let state = self.state.as_mut().unwrap();
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        let rects = frame.shadows.pack()?;
        let validation = state.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = state
            .device
            .push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = state.device.push_error_scope(wgpu::ErrorFilter::Internal);
        let signature = if rects.is_empty() {
            state.shadows.remove(view);
            None
        } else {
            // Camera direction selects cascades during sampling. The depth
            // projections already capture every camera change that affects
            // rasterization, so direction alone must not invalidate the atlas.
            let mut depth_frame = frame.shadows.clone();
            depth_frame.forward = [0.; 3];
            let signature = Signature {
                frame: depth_frame,
                casters: frame
                    .meshes
                    .iter()
                    .filter(|m| m.cast_shadow)
                    .map(|m| Caster {
                        geometry: m.geometry,
                        instances: m.instances,
                        pose: m.pose,
                        instance_count: m.instance_count,
                        key: state.geometries[&m.geometry].key,
                        model: m.model,
                        side: m.side,
                        alpha_mode: m.alpha_mode,
                        vertex_colors: m.vertex_colors,
                        opacity: m.opacity,
                        cutoff: m.alpha_cutoff,
                        map: if m.alpha_mode == 1 {
                            m.color_map.clone()
                        } else {
                            None
                        },
                    })
                    .collect(),
            };
            let atlas = state.shadows.atlases.entry(view).or_insert_with(|| Atlas {
                texture: depth_texture(&state.device, ATLAS_SIZE),
                signature: None,
            });
            (atlas.signature.as_ref() != Some(&signature)).then_some(signature)
        };
        let atlas = state
            .shadows
            .atlases
            .get(&view)
            .map_or(&state.shadows.empty, |a| &a.texture)
            .create_view(&Default::default());
        let mut uniform = ShadowUniform::zeroed();
        uniform.forward[..3].copy_from_slice(&frame.shadows.forward);
        for (i, (view, rect)) in frame.shadows.views.iter().zip(&rects).enumerate() {
            let light = &mut uniform.lights[view.light_index as usize];
            if light[1] == 0 {
                light[0] = i as u32;
                light[2] = view.kind;
            }
            light[1] += 1;
            uniform.views[i] = ViewUniform {
                projection: view.view_projection,
                rect: [
                    rect.x as f32 / ATLAS_SIZE as f32,
                    rect.y as f32 / ATLAS_SIZE as f32,
                    rect.size as f32 / ATLAS_SIZE as f32,
                    0.,
                ],
                params: [
                    view.bias,
                    view.normal_bias,
                    view.slope_bias,
                    view.filter_radius,
                ],
                interval: [view.near, view.far, view.blend, view.strength],
            };
        }
        let uniform = state
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("shadow views"),
                contents: bytemuck::bytes_of(&uniform),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let mut draws = Vec::new();
        if signature.is_some() {
            for view in &frame.shadows.views {
                let vp = Mat4::from_cols_array(&view.view_projection);
                let mut view_draws = Vec::new();
                for (index, mesh) in frame
                    .meshes
                    .iter()
                    .enumerate()
                    .filter(|(_, m)| m.cast_shadow)
                {
                    let key = PipelineKey::new(mesh);
                    if !state.shadows.pipelines.contains_key(&key) {
                        let pipeline = state.shadows.pipeline(&state.device, key);
                        state.shadows.pipelines.insert(key, pipeline);
                    }
                    let params = DepthUniform {
                        side: [
                            if mesh.instances != 0 {
                                mesh.side as f32
                            } else {
                                0.
                            },
                            0.,
                            0.,
                            0.,
                        ],
                        mvp: (vp * Mat4::from_cols_array(&mesh.model)).to_cols_array(),
                        params: [
                            mesh.opacity,
                            mesh.alpha_cutoff,
                            if mesh.alpha_mode == 1 { 1. } else { 0. },
                            mesh.color_map.as_ref().map_or(0., |m| m.uv_set as f32),
                        ],
                    };
                    let buffer =
                        state
                            .device
                            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                                label: Some("shadow caster"),
                                contents: bytemuck::bytes_of(&params),
                                usage: wgpu::BufferUsages::UNIFORM,
                            });
                    let binding = state.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("shadow caster"),
                        layout: &state.shadows.layout,
                        entries: &[wgpu::BindGroupEntry {
                            binding: 0,
                            resource: buffer.as_entire_binding(),
                        }],
                    });
                    view_draws.push(CasterDraw {
                        mesh: index,
                        binding,
                        alpha: None,
                    });
                }
                draws.push(view_draws);
            }
        }
        // Use the ordinary base-color sampler, UV set and alpha cutoff for masked depth.
        for view_draws in &mut draws {
            for draw in view_draws {
                let mesh = &frame.meshes[draw.mesh];
                if PipelineKey::new(mesh).textured {
                    let (texture, sampler) = self.texture_parts(mesh.color_map.as_ref().unwrap());
                    draw.alpha = Some(self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("shadow alpha mask"),
                        layout: &self.texture_layout,
                        entries: &[
                            wgpu::BindGroupEntry {
                                binding: 0,
                                resource: wgpu::BindingResource::TextureView(&texture),
                            },
                            wgpu::BindGroupEntry {
                                binding: 1,
                                resource: wgpu::BindingResource::Sampler(&sampler),
                            },
                        ],
                    }));
                }
            }
        }
        let mut error = None;
        for scope in [internal, memory, validation] {
            if let Some(failure) = pollster::block_on(scope.pop()) {
                error = Some(failure.to_string());
            }
        }
        if let Some(error) = error {
            self.failure = Some(error.clone());
            return Err(error);
        }
        Ok(PreparedShadows {
            view,
            uniform,
            atlas,
            rects,
            draws,
            signature,
        })
    }
    pub(super) fn accept_shadows(&mut self, prepared: PreparedShadows) {
        if let Some(signature) = prepared.signature {
            self.shadows.rendered_views += prepared.rects.len() as u64;
            self.shadows
                .atlases
                .get_mut(&prepared.view)
                .unwrap()
                .signature = Some(signature);
        } else if !prepared.rects.is_empty() {
            self.shadows.reused_frames += 1;
        }
    }
}
