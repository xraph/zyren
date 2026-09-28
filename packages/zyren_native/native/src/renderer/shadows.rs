use super::*;
use crate::scene::Mesh;
use glam::Vec3;
mod projection;
use projection::projections;
const MAX_BYTES: u64 = 64 * 1024 * 1024;
#[derive(Clone, PartialEq)]
struct Signature {
    casters: Vec<Mesh>,
    lights: Vec<[f32; 20]>,
    settings: Vec<[f32; 8]>,
    camera: [f32; 16],
    clip: [f32; 2],
    origin: [f64; 3],
}
struct Map {
    matrix: Mat4,
    rect: [u32; 4],
    light: u32,
    bias: f32,
    normal_bias: f32,
    end: f32,
}
struct View {
    signature: Signature,
    maps: Vec<Map>,
    atlas: wgpu::Texture,
    depth: wgpu::TextureView,
    dirty: bool,
    camera: Vec3,
}
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
struct Pipeline {
    side: u32,
    mirrored: bool,
    textured: bool,
    instanced: bool,
}
pub(super) struct Shadows {
    views: HashMap<u64, View>,
    pub passes: u64,
    pipelines: HashMap<Pipeline, wgpu::RenderPipeline>,
    uniforms: wgpu::BindGroupLayout,
    layout: wgpu::PipelineLayout,
    shader: wgpu::ShaderModule,
    empty: wgpu::Texture,
    pub sampler: wgpu::Sampler,
}
impl Shadows {
    pub fn new(device: &wgpu::Device, textures: &wgpu::BindGroupLayout) -> Self {
        let uniforms = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("shadow uniforms"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX_FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: wgpu::BufferSize::new(256),
                },
                count: None,
            }],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("shadow caster"),
            bind_group_layouts: &[Some(&uniforms), Some(textures)],
            ..Default::default()
        });
        Self {
            views: HashMap::new(),
            passes: 0,
            pipelines: HashMap::new(),
            uniforms,
            layout,
            shader: device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("instance shadows"),
                source: wgpu::ShaderSource::Wgsl(
                    concat!(
                        include_str!("coverage.wgsl"),
                        "\n",
                        include_str!("instance.wgsl"),
                        "\n",
                        include_str!("shadow.wgsl")
                    )
                    .into(),
                ),
            }),
            empty: atlas(device, 1, 1),
            sampler: device.create_sampler(&wgpu::SamplerDescriptor {
                label: Some("shadow comparison"),
                compare: Some(wgpu::CompareFunction::LessEqual),
                mag_filter: wgpu::FilterMode::Linear,
                min_filter: wgpu::FilterMode::Linear,
                ..Default::default()
            }),
        }
    }
    pub fn bytes(&self) -> u64 {
        self.views
            .values()
            .map(|v| v.atlas.width() as u64 * v.atlas.height() as u64 * 4)
            .sum()
    }
    pub fn remove(&mut self, id: u64) {
        self.views.remove(&id);
    }
    pub fn accept(&mut self, frame: &Frame) {
        if let Some(v) = self.views.get_mut(&view_id(frame))
            && v.dirty
        {
            self.passes += v.maps.len() as u64;
            v.dirty = false;
        }
    }
    pub fn admit(&self, frame: &Frame) -> Result<(), String> {
        crate::scene::validate_shadows(&frame.settings, &frame.lights)?;
        if frame.settings.shadows.is_empty() {
            return Ok(());
        }
        let count: u32 = frame.settings.shadows.iter().map(|s| s[2] as u32).sum();
        let cell = frame
            .settings
            .shadows
            .iter()
            .map(|s| s[1] as u32)
            .max()
            .unwrap();
        let columns = (count as f32).sqrt().ceil() as u32;
        let bytes = columns as u64 * count.div_ceil(columns) as u64 * cell as u64 * cell as u64 * 4;
        let previous = self
            .views
            .get(&view_id(frame))
            .map_or(0, |v| v.atlas.width() as u64 * v.atlas.height() as u64 * 4);
        if self.bytes() - previous + bytes > MAX_BYTES {
            return Err("Shadow atlas budget exceeded".into());
        }
        Ok(())
    }
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        frame: &Frame,
        geometries: &HashMap<u32, GpuGeometry>,
    ) -> Result<(), String> {
        let id = view_id(frame);
        self.admit(frame)?;
        if frame.settings.shadows.is_empty() {
            self.views.remove(&id);
            return Ok(());
        }
        let signature = Signature {
            casters: frame
                .meshes
                .iter()
                .filter(|m| m.shadow_flags & 1 != 0 && m.alpha_mode != 2)
                .cloned()
                .collect(),
            lights: frame.lights.clone(),
            settings: frame.settings.shadows.clone(),
            camera: frame.view_projection,
            clip: frame.settings.shadow_camera,
            origin: frame.settings.camera_origin,
        };
        if self
            .views
            .get(&id)
            .is_some_and(|v| v.signature == signature)
        {
            return Ok(());
        }
        let count: usize = signature.settings.iter().map(|s| s[2] as usize).sum();
        let cell = signature
            .settings
            .iter()
            .map(|s| s[1] as u32)
            .max()
            .unwrap();
        let columns = (count as f32).sqrt().ceil() as u32;
        let width = columns * cell;
        let height = (count as u32).div_ceil(columns) * cell;
        let previous = self
            .views
            .get(&id)
            .map_or(0, |v| v.atlas.width() as u64 * v.atlas.height() as u64 * 4);
        if self.bytes() - previous + width as u64 * height as u64 * 4 > MAX_BYTES {
            return Err("Shadow atlas budget exceeded".into());
        }
        let (maps, camera) = projections(frame, &signature, geometries, columns, cell)?;
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        let mut pending = HashMap::new();
        for mesh in &signature.casters {
            let base = pipeline_key(mesh);
            let keys = if base.instanced {
                vec![
                    Pipeline {
                        mirrored: false,
                        ..base
                    },
                    Pipeline {
                        mirrored: true,
                        ..base
                    },
                ]
            } else {
                vec![base]
            };
            for key in keys {
                if !self.pipelines.contains_key(&key) && !pending.contains_key(&key) {
                    pending.insert(key, self.pipeline(device, key));
                }
            }
        }
        let texture = self
            .views
            .get(&id)
            .filter(|v| v.atlas.width() == width && v.atlas.height() == height)
            .map_or_else(|| atlas(device, width, height), |v| v.atlas.clone());
        let depth = texture.create_view(&Default::default());
        let mut failure = None;
        for scope in [internal, memory, validation] {
            if let Some(error) = pollster::block_on(scope.pop()) {
                failure = Some(error.to_string());
            }
        }
        if let Some(error) = failure {
            return Err(error);
        }
        self.pipelines.extend(pending);
        self.views.insert(
            id,
            View {
                signature,
                maps,
                atlas: texture,
                depth,
                dirty: true,
                camera,
            },
        );
        Ok(())
    }
    fn pipeline(&self, device: &wgpu::Device, key: Pipeline) -> wgpu::RenderPipeline {
        let vertices = wgpu::vertex_attr_array![0=>Float32x3,1=>Float32x3];
        let uv = wgpu::vertex_attr_array![2=>Float32x2,3=>Float32x2];
        let mut buffers = vec![Some(wgpu::VertexBufferLayout {
            array_stride: 24,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &vertices,
        })];
        if key.textured {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: 16,
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: &uv,
            }));
        }
        if key.instanced {
            buffers.resize_with(3, || None);
            buffers.push(Some(super::instances::layout()));
        }
        let entry = match (key.textured, key.instanced) {
            (false, false) => "plain",
            (true, false) => "textured",
            (false, true) => "plain_instanced",
            (true, true) => "textured_instanced",
        };
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("shadow caster"),
            layout: Some(&self.layout),
            vertex: wgpu::VertexState {
                module: &self.shader,
                entry_point: Some(entry),
                compilation_options: Default::default(),
                buffers: &buffers,
            },
            fragment: Some(wgpu::FragmentState {
                module: &self.shader,
                entry_point: Some("fragment"),
                compilation_options: Default::default(),
                targets: &[],
            }),
            primitive: wgpu::PrimitiveState {
                front_face: if key.mirrored {
                    wgpu::FrontFace::Cw
                } else {
                    wgpu::FrontFace::Ccw
                },
                cull_mode: match key.side {
                    1 => Some(wgpu::Face::Back),
                    2 => Some(wgpu::Face::Front),
                    _ => None,
                },
                ..Default::default()
            },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: wgpu::TextureFormat::Depth32Float,
                depth_write_enabled: Some(true),
                depth_compare: Some(wgpu::CompareFunction::Less),
                stencil: Default::default(),
                bias: Default::default(),
            }),
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        })
    }
    pub fn globals(
        &self,
        device: &wgpu::Device,
        frame: &Frame,
    ) -> (wgpu::Buffer, wgpu::TextureView) {
        let mut values = [0_f32; 196];
        let texture = if let Some(v) = self.views.get(&view_id(frame)) {
            values[..3].copy_from_slice(&v.camera.to_array());
            values[3] = v.maps.len() as f32;
            for (i, map) in v.maps.iter().enumerate() {
                let start = 4 + i * 24;
                values[start..start + 16].copy_from_slice(&map.matrix.to_cols_array());
                values[start + 16..start + 20].copy_from_slice(&[
                    map.rect[0] as f32 / v.atlas.width() as f32,
                    map.rect[1] as f32 / v.atlas.height() as f32,
                    map.rect[2] as f32 / v.atlas.width() as f32,
                    map.rect[3] as f32 / v.atlas.height() as f32,
                ]);
                values[start + 20..start + 24].copy_from_slice(&[
                    map.light as f32,
                    map.bias,
                    map.normal_bias,
                    map.end,
                ]);
            }
            &v.atlas
        } else {
            &self.empty
        };
        (
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("shadow sampling"),
                contents: bytemuck::cast_slice(&values),
                usage: wgpu::BufferUsages::UNIFORM,
            }),
            texture.create_view(&Default::default()),
        )
    }
}
fn view_id(frame: &Frame) -> u64 {
    frame.binary.as_ref().map_or(0, |v| v.view)
}
fn up(d: Vec3) -> Vec3 {
    if d.y.abs() > 0.99 { Vec3::X } else { Vec3::Y }
}
fn pipeline_key(m: &Mesh) -> Pipeline {
    Pipeline {
        side: m.side,
        mirrored: Mat4::from_cols_array(&m.model).determinant() < 0.,
        textured: m.color_map.is_some(),
        instanced: !m.instances.is_empty(),
    }
}
fn atlas(device: &wgpu::Device, width: u32, height: u32) -> wgpu::Texture {
    device.create_texture(&wgpu::TextureDescriptor {
        label: Some("shadow atlas"),
        size: wgpu::Extent3d {
            width,
            height,
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

impl Renderer {
    pub(super) fn prepare_shadows(&mut self, frame: &Frame) -> Result<(), String> {
        let state = self.state.as_mut().unwrap();
        state
            .shadows
            .prepare(&state.device, frame, &state.geometries)
    }
    pub(super) fn encode_shadows(&self, frame: &Frame, encoder: &mut wgpu::CommandEncoder) {
        let Some(view) = self.shadows.views.get(&view_id(frame)).filter(|v| v.dirty) else {
            return;
        };
        let textures: Vec<_> = frame
            .meshes
            .iter()
            .map(|m| match &m.color_map {
                Some(map) => self.texture_binding(map),
                None => {
                    let texture = self.pbr_white.create_view(&Default::default());
                    let sampler = self.device.create_sampler(&Default::default());
                    self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some("opaque shadow"),
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
                    })
                }
            })
            .collect();
        let bindings: Vec<Vec<_>> = view
            .maps
            .iter()
            .map(|map| {
                frame
                    .meshes
                    .iter()
                    .map(|mesh| {
                        let mut values = (map.matrix
                            * if mesh.instances.is_empty() {
                                Mat4::from_cols_array(&mesh.model)
                            } else {
                                Mat4::IDENTITY
                            })
                        .to_cols_array()
                        .to_vec();
                        values.extend([
                            mesh.color_map.as_ref().map_or(0., |m| m.uv_set as f32),
                            mesh.opacity,
                            mesh.alpha_cutoff,
                            if mesh.alpha_mode == 1 { 1. } else { 0. },
                        ]);
                        values.extend(mesh.model);
                        values.extend(section_planes(mesh).into_iter().flatten());
                        values.extend([
                            mesh.clipping_planes.len() as f32,
                            mesh.coverage[0],
                            mesh.coverage[1],
                            0.,
                        ]);
                        let buffer =
                            self.device
                                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                                    label: Some("shadow caster"),
                                    contents: bytemuck::cast_slice(&values),
                                    usage: wgpu::BufferUsages::UNIFORM,
                                });
                        self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                            label: Some("shadow caster"),
                            layout: &self.shadows.uniforms,
                            entries: &[wgpu::BindGroupEntry {
                                binding: 0,
                                resource: buffer.as_entire_binding(),
                            }],
                        })
                    })
                    .collect()
            })
            .collect();
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("shadow atlas"),
            color_attachments: &[],
            depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                view: &view.depth,
                depth_ops: Some(wgpu::Operations {
                    load: wgpu::LoadOp::Clear(1.),
                    store: wgpu::StoreOp::Store,
                }),
                stencil_ops: None,
            }),
            ..Default::default()
        });
        for (i, map) in view.maps.iter().enumerate() {
            pass.set_viewport(
                map.rect[0] as f32,
                map.rect[1] as f32,
                map.rect[2] as f32,
                map.rect[3] as f32,
                0.,
                1.,
            );
            pass.set_scissor_rect(map.rect[0], map.rect[1], map.rect[2], map.rect[3]);
            let instances = self.instances.view(frame);
            for draw in &instances.draws {
                let j = draw.mesh;
                let mesh = &frame.meshes[j];
                if mesh.shadow_flags & 1 == 0 || mesh.alpha_mode == 2 {
                    continue;
                }
                let key = Pipeline {
                    mirrored: draw.mirrored,
                    ..pipeline_key(mesh)
                };
                pass.set_pipeline(&self.shadows.pipelines[&key]);
                pass.set_bind_group(0, &bindings[i][j], &[]);
                pass.set_bind_group(1, &textures[j], &[]);
                let (vertices, indices, count, uv, format, _) =
                    self.resources.geometry(self.geometries[&mesh.geometry].key);
                pass.set_vertex_buffer(0, vertices.slice(..));
                if mesh.color_map.is_some() {
                    pass.set_vertex_buffer(1, uv.expect("validated UVs").slice(..));
                }
                pass.set_index_buffer(indices.slice(..), format);
                if draw.instanced {
                    pass.set_vertex_buffer(
                        3,
                        instances
                            .buffer
                            .as_ref()
                            .expect("instance buffer")
                            .slice(..),
                    );
                }
                pass.draw_indexed(0..count, 0, draw.range.clone());
            }
        }
    }
}
