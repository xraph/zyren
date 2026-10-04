use super::{GraphError, bindings, compile::check_entry, descriptor::*, key, key_value, scoped};
use crate::{
    resources::{
        ResourceStore,
        registry::{ResourceKey, ResourceRegistry, next_registry_id},
    },
    scene::Mesh,
    shaders::ShaderStore,
};
use serde::Deserialize;
use std::{
    collections::HashMap,
    sync::{Arc, Weak},
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Description {
    label: String,
    program: Key,
    bindings: Vec<Binding>,
    vertex_layout: u32,
    #[serde(default)]
    geometry: u32,
    #[serde(default)]
    scene_inputs: u32,
    vertex_entry_point: String,
    fragment_entry_point: String,
}
#[derive(Clone, Copy, Hash, PartialEq, Eq)]
struct State {
    sample_count: u32,
    format: wgpu::TextureFormat,
    side: u32,
    mirrored: bool,
    blend: bool,
    reversed_depth: bool,
    outline_pass: bool,
    depth_test: bool,
    depth_write: bool,
}
impl State {
    fn new(format: wgpu::TextureFormat, mesh: &Mesh, sample_count: u32) -> Self {
        Self {
            sample_count,
            format,
            side: mesh.side,
            mirrored: glam::Mat4::from_cols_array(&mesh.model).determinant() < 0.,
            blend: mesh.alpha_mode == 2,
            reversed_depth: mesh.reversed_depth,
            outline_pass: mesh.outline_pass,
            depth_test: mesh.depth_test,
            depth_write: !mesh.outline_pass && mesh.writes_depth(),
        }
    }
}
#[derive(Clone, Hash, PartialEq, Eq)]
struct PipelineKey {
    module: wgpu::ShaderModule,
    bindings: Vec<bindings::LayoutKey>,
    vertex: String,
    fragment: String,
    uv: bool,
    tangent: bool,
    colored: bool,
    instanced: bool,
    deformed: bool,
    scene_inputs: bool,
    blend_override: Option<Blend>,
    state: State,
}
struct Pipeline {
    native: wgpu::RenderPipeline,
    layout: wgpu::PipelineLayout,
    groups: Vec<wgpu::BindGroupLayout>,
}
struct Program {
    label: String,
    key: PipelineKey,
    prototype: Arc<Pipeline>,
    groups: Vec<Option<wgpu::BindGroup>>,
    resources: Vec<ResourceKey>,
    shader: ResourceKey,
}
#[derive(Clone)]
pub(crate) struct PreparedMaterial {
    pipeline: Arc<Pipeline>,
    groups: Vec<Option<wgpu::BindGroup>>,
    pub resources: Vec<ResourceKey>,
    pub uv: bool,
    pub tangent: bool,
    pub colored: bool,
    pub scene_input_layout: Option<wgpu::BindGroupLayout>,
}
impl PreparedMaterial {
    pub(crate) fn bind_group_count(&self) -> u64 {
        self.groups.iter().flatten().count() as u64
    }
    pub fn bind(&self, pass: &mut wgpu::RenderPass<'_>) {
        pass.set_pipeline(&self.pipeline.native);
        for (index, group) in self.groups.iter().enumerate() {
            if let Some(group) = group {
                pass.set_bind_group(index as u32 + 1, group, &[]);
            }
        }
    }
}
pub(crate) struct MeshStore {
    registry: ResourceRegistry<Program>,
    cache: HashMap<PipelineKey, Weak<Pipeline>>,
    owned: HashMap<(ResourceKey, State), Arc<Pipeline>>,
}
impl Default for MeshStore {
    fn default() -> Self {
        Self {
            registry: ResourceRegistry::new(next_registry_id(), 1, 16 * 1024 * 1024),
            cache: HashMap::new(),
            owned: HashMap::new(),
        }
    }
}
fn create_pipeline(
    device: &wgpu::Device,
    key: &PipelineKey,
    layout: &wgpu::PipelineLayout,
) -> wgpu::RenderPipeline {
    let attributes = wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3];
    let uv = wgpu::vertex_attr_array![2 => Float32x2, 3 => Float32x2];
    let tangent = wgpu::vertex_attr_array![4 => Float32x4];
    let color = wgpu::vertex_attr_array![5 => Float32x4];
    let instance = wgpu::vertex_attr_array![6=>Float32x4,7=>Float32x4,8=>Float32x4,9=>Float32x4,10=>Float32x4,11=>Float32x4,12=>Float32x4,13=>Float32x3];
    let mut buffers = vec![Some(wgpu::VertexBufferLayout {
        array_stride: 24,
        step_mode: wgpu::VertexStepMode::Vertex,
        attributes: &attributes,
    })];
    if key.uv {
        buffers.push(Some(wgpu::VertexBufferLayout {
            array_stride: 16,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &uv,
        }));
    }
    if key.tangent {
        buffers.push(Some(wgpu::VertexBufferLayout {
            array_stride: 16,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &tangent,
        }));
    }
    if key.colored {
        buffers.push(Some(wgpu::VertexBufferLayout {
            array_stride: 16,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &color,
        }));
    }
    if key.instanced {
        buffers.push(Some(wgpu::VertexBufferLayout {
            array_stride: crate::instances::INSTANCE_STRIDE as u64,
            step_mode: wgpu::VertexStepMode::Instance,
            attributes: &instance,
        }));
    }
    let state = key.state;
    device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("custom mesh material"),
        layout: Some(layout),
        vertex: wgpu::VertexState {
            module: &key.module,
            entry_point: Some(&key.vertex),
            compilation_options: Default::default(),
            buffers: &buffers,
        },
        fragment: Some(wgpu::FragmentState {
            module: &key.module,
            entry_point: Some(&key.fragment),
            compilation_options: Default::default(),
            targets: &[Some(wgpu::ColorTargetState {
                format: state.format,
                blend: match key.blend_override {
                    Some(blend) => blend.state(),
                    None => state.blend.then_some(wgpu::BlendState::ALPHA_BLENDING),
                },
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: wgpu::PrimitiveState {
            front_face: if state.mirrored {
                wgpu::FrontFace::Cw
            } else {
                wgpu::FrontFace::Ccw
            },
            cull_mode: match if key.instanced { 0 } else { state.side } {
                1 => Some(wgpu::Face::Back),
                2 => Some(wgpu::Face::Front),
                _ => None,
            },
            ..Default::default()
        },
        depth_stencil: Some(wgpu::DepthStencilState {
            format: wgpu::TextureFormat::Depth32Float,
            depth_write_enabled: Some(state.depth_write),
            depth_compare: Some(if state.depth_test {
                match (state.reversed_depth, state.outline_pass) {
                    (true, true) => wgpu::CompareFunction::GreaterEqual,
                    (true, false) => wgpu::CompareFunction::Greater,
                    (false, true) => wgpu::CompareFunction::LessEqual,
                    (false, false) => wgpu::CompareFunction::Less,
                }
            } else {
                wgpu::CompareFunction::Always
            }),
            stencil: Default::default(),
            bias: Default::default(),
        }),
        multisample: wgpu::MultisampleState {
            count: state.sample_count,
            ..Default::default()
        },
        multiview_mask: None,
        cache: None,
    })
}
impl MeshStore {
    pub fn scene_inputs(&self, id: ResourceKey) -> Result<bool, GraphError> {
        Ok(self.registry.resolve(id)?.key.scene_inputs)
    }
    pub fn count(&self) -> u64 {
        self.registry.live_allocations()
    }
    pub fn pipelines(&mut self) -> usize {
        self.cache.retain(|_, value| value.strong_count() > 0);
        self.cache.len()
    }
    pub(super) fn compile(
        &mut self,
        context: &mut super::GraphContext<'_>,
        description: Description,
        bytes: u64,
    ) -> Result<Key, GraphError> {
        let device = context.device;
        if self.count() >= 4096
            || self.owned.len() >= 8192
            || description.label.len() > 1024
            || description.vertex_layout > 5
            || description.geometry > 3
            || description.scene_inputs > 1
        {
            return Err(GraphError::new(
                "limitExceeded",
                "Mesh shader exceeds program, label or vertex layout limits",
            ));
        }
        self.registry.check_capacity(bytes)?;
        if description.bindings.iter().any(|b| {
            b.group == 0
                || (description.geometry & 2 != 0 && b.group == 2)
                || (description.scene_inputs != 0 && b.group == 3)
                || matches!(
                    b.kind,
                    BindingKind::StorageReadWrite | BindingKind::StorageTexture
                )
        }) {
            return Err(GraphError::new(
                "invalidBinding",
                "Mesh bindings must read from groups one to three; deformed programs reserve group two",
            ));
        }
        let shader = context.shaders.resolve(key(description.program))?;
        check_entry(shader, &description.vertex_entry_point, "vertex")?;
        check_entry(shader, &description.fragment_entry_point, "fragment")?;
        let pass = Pass {
            kind: Kind::Render,
            name: description.label.clone(),
            program: description.program,
            bindings: description.bindings,
            reads: vec![],
            writes: vec![],
            after: vec![],
            entry_point: None,
            workgroups: None,
            vertex_entry_point: None,
            fragment_entry_point: None,
            vertex_count: None,
            instance_count: None,
            sample_count: None,
            color: None,
            blend: None,
            requires_uv: None,
            scene_inputs: None,
            screen_space: None,
            screen_stage: None,
            screen_target: None,
        };
        let (pipeline_key, pipeline, groups, resources) =
            scoped(device, &description.label, || {
                let bindings = bindings::prepare(device, context.resources, &pass)?;
                let cache_key = PipelineKey {
                    blend_override: None,
                    module: shader.module.clone(),
                    bindings: bindings.keys,
                    vertex: description.vertex_entry_point,
                    fragment: description.fragment_entry_point,
                    uv: matches!(description.vertex_layout, 1 | 2 | 4 | 5),
                    tangent: matches!(description.vertex_layout, 2 | 5),
                    colored: description.vertex_layout >= 3,
                    instanced: description.geometry & 1 != 0,
                    deformed: description.geometry & 2 != 0,
                    scene_inputs: description.scene_inputs != 0,
                    state: State::new(wgpu::TextureFormat::Rgba8UnormSrgb, &Mesh::default(), 1),
                };
                let pipeline = if let Some(p) = self.cache.get(&cache_key).and_then(Weak::upgrade) {
                    p
                } else {
                    let mut groups = vec![context.mesh_layout.clone()];
                    let count = bindings.layouts.len().max(if cache_key.scene_inputs {
                        4
                    } else if cache_key.deformed {
                        3
                    } else {
                        1
                    });
                    for index in 1..count {
                        groups.push(if cache_key.scene_inputs && index == 3 {
                            crate::renderer::scene_inputs::layout(device)
                        } else if cache_key.deformed && index == 2 {
                            context.deformation_layout.clone()
                        } else {
                            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                                label: Some(&description.label),
                                entries: bindings.layouts.get(index).map_or(&[], Vec::as_slice),
                            })
                        });
                    }
                    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                        label: Some(&description.label),
                        bind_group_layouts: &groups.iter().map(Some).collect::<Vec<_>>(),
                        immediate_size: 0,
                    });
                    Arc::new(Pipeline {
                        native: create_pipeline(device, &cache_key, &layout),
                        layout,
                        groups,
                    })
                };
                let groups = (1..pipeline.groups.len())
                    .map(|index| {
                        if (cache_key.deformed && index == 2)
                            || (cache_key.scene_inputs && index == 3)
                        {
                            return None;
                        }
                        Some(
                            device.create_bind_group(&wgpu::BindGroupDescriptor {
                                label: Some(&description.label),
                                layout: &pipeline.groups[index],
                                entries: &bindings
                                    .resources
                                    .get(index)
                                    .map_or(&[][..], Vec::as_slice)
                                    .iter()
                                    .map(|(slot, resource)| wgpu::BindGroupEntry {
                                        binding: *slot,
                                        resource: resource.binding(),
                                    })
                                    .collect::<Vec<_>>(),
                            }),
                        )
                    })
                    .collect();
                Ok((
                    cache_key,
                    pipeline,
                    groups,
                    bindings.reads.into_iter().map(key).collect::<Vec<_>>(),
                ))
            })?;
        context.resources.retain_graph(&resources)?;
        let shader_key = key(description.program);
        if let Err(error) = context.shaders.retain_graph(&[shader_key]) {
            context.resources.release_graph(device, &resources)?;
            return Err(error.into());
        }
        let program = Program {
            label: description.label,
            key: pipeline_key.clone(),
            prototype: pipeline.clone(),
            groups,
            resources: resources.clone(),
            shader: shader_key,
        };
        match self.registry.insert(program, bytes) {
            Ok(id) => {
                self.cache
                    .insert(pipeline_key.clone(), Arc::downgrade(&pipeline));
                self.owned.insert((id, pipeline_key.state), pipeline);
                Ok(key_value(id))
            }
            Err(error) => {
                context.resources.release_graph(device, &resources)?;
                context.shaders.release_graph(&[shader_key])?;
                Err(error.into())
            }
        }
    }
    pub(crate) fn retain_cover(&mut self, key: ResourceKey) -> Result<(), GraphError> {
        self.registry.retain(key).map_err(Into::into)
    }
    pub fn release(
        &mut self,
        device: &wgpu::Device,
        resources: &mut ResourceStore,
        shaders: &mut ShaderStore,
        id: ResourceKey,
    ) -> Result<(), GraphError> {
        if self.registry.references(id)? > 1 {
            self.registry.release(id)?;
            return Ok(());
        }
        let program = self.registry.resolve(id)?;
        let keys = program.resources.clone();
        let shader = program.shader;
        self.registry.release(id)?;
        self.registry.retire_completed(0);
        self.owned.retain(|(owner, _), _| *owner != id);
        self.cache.retain(|_, p| p.strong_count() > 0);
        let resources_result = resources.release_graph(device, &keys);
        let shaders_result = shaders.release_graph(&[shader]);
        resources_result?;
        shaders_result?;
        Ok(())
    }
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        id: ResourceKey,
        mesh: &Mesh,
        format: wgpu::TextureFormat,
        sample_count: u32,
    ) -> Result<PreparedMaterial, GraphError> {
        let program = self.registry.resolve(id)?;
        if mesh.primitive_kind != 0 || mesh.color_map.is_some() {
            return Err(GraphError::new(
                "invalidDescriptor",
                "Custom mesh shaders require triangle geometry and scoped texture bindings",
            ));
        }
        if program.key.instanced != (mesh.instances != 0)
            || program.key.deformed != (mesh.pose != 0)
        {
            return Err(GraphError::new(
                "invalidDescriptor",
                "Mesh geometry does not match the shader profile",
            ));
        }
        let state = State::new(format, mesh, sample_count);
        let pipeline = if let Some(pipeline) = self.owned.get(&(id, state)) {
            pipeline.clone()
        } else {
            if self.owned.len() >= 8192 {
                return Err(GraphError::new(
                    "limitExceeded",
                    "Mesh pipeline variant budget exceeded",
                ));
            }
            let mut cache_key = program.key.clone();
            cache_key.state = state;
            let pipeline = if let Some(p) = self.cache.get(&cache_key).and_then(Weak::upgrade) {
                p
            } else {
                scoped(device, &program.label, || {
                    Ok(Arc::new(Pipeline {
                        native: create_pipeline(device, &cache_key, &program.prototype.layout),
                        layout: program.prototype.layout.clone(),
                        groups: program.prototype.groups.clone(),
                    }))
                })?
            };
            self.cache.insert(cache_key, Arc::downgrade(&pipeline));
            self.owned.insert((id, state), pipeline.clone());
            pipeline
        };
        Ok(PreparedMaterial {
            pipeline,
            groups: program.groups.clone(),
            resources: program.resources.clone(),
            uv: program.key.uv,
            tangent: program.key.tangent,
            colored: program.key.colored,
            scene_input_layout: program
                .key
                .scene_inputs
                .then(|| program.prototype.groups[3].clone()),
        })
    }
}

pub(super) fn prepare_external(
    device: &wgpu::Device,
    material: &super::materials::PreparedMaterial,
    mesh: &Mesh,
    format: wgpu::TextureFormat,
    samples: u32,
) -> Result<PreparedMaterial, GraphError> {
    if material.screen_pipeline.is_some()
        || mesh.instances != 0
        || mesh.pose != 0
        || mesh.primitive_kind != 0
    {
        return Err(GraphError::new(
            "invalidDescriptor",
            "This material requires rigid triangle geometry",
        ));
    }
    let key = PipelineKey {
        blend_override: material.blend,
        module: material.shader.clone(),
        bindings: vec![],
        vertex: material.vertex.clone(),
        fragment: material.fragment.clone(),
        uv: material.requires_uv,
        tangent: false,
        colored: false,
        instanced: false,
        deformed: false,
        scene_inputs: material.scene_input_layout.is_some(),
        state: State::new(format, mesh, samples),
    };
    let pipeline = scoped(device, "mesh material", || {
        Ok(Arc::new(Pipeline {
            native: create_pipeline(device, &key, &material.layout),
            layout: material.layout.clone(),
            groups: vec![],
        }))
    })?;
    Ok(PreparedMaterial {
        pipeline,
        groups: material.groups.iter().cloned().map(Some).collect(),
        resources: material.resources.clone(),
        uv: material.requires_uv,
        tangent: false,
        colored: false,
        scene_input_layout: material.scene_input_layout.clone(),
    })
}
