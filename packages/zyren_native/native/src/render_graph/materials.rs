use super::{GraphError, bindings, descriptor::*, key, key_value, scoped};
use crate::{
    resources::{
        ResourceError, ResourceStore,
        registry::{ResourceKey, ResourceRegistry, next_registry_id},
    },
    shaders::ShaderStore,
};
use std::collections::{HashMap, HashSet};

pub(crate) struct PreparedMaterial {
    pub shader: wgpu::ShaderModule,
    pub layout: wgpu::PipelineLayout,
    pub groups: Vec<wgpu::BindGroup>,
    pub vertex: String,
    pub fragment: String,
    pub requires_uv: bool,
    pub blend: Option<Blend>,
    pub screen_stage: u32,
    pub screen_target: Option<wgpu::TextureView>,
    pub screen_pipeline: Option<wgpu::RenderPipeline>,
    pub(crate) resources: Vec<ResourceKey>,
    program: ResourceKey,
}
type DrawKey = (
    Key,
    wgpu::TextureFormat,
    u32,
    u32,
    u32,
    bool,
    bool,
    bool,
    bool,
    bool,
);
pub(crate) struct MaterialStore {
    pipelines: HashMap<DrawKey, super::mesh::PreparedMaterial>,
    registry: ResourceRegistry<PreparedMaterial>,
}
impl Default for MaterialStore {
    fn default() -> Self {
        Self {
            pipelines: HashMap::new(),
            registry: ResourceRegistry::new(next_registry_id(), 1, 8 * 1024 * 1024),
        }
    }
}
impl MaterialStore {
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        value: Key,
        mesh: &crate::scene::Mesh,
        format: wgpu::TextureFormat,
        samples: u32,
    ) -> Result<super::mesh::PreparedMaterial, GraphError> {
        let material = self.resolve(value)?;
        let key = (
            value,
            format,
            samples,
            mesh.side,
            mesh.alpha_mode,
            glam::Mat4::from_cols_array(&mesh.model).determinant() < 0.,
            mesh.depth_test,
            mesh.writes_depth(),
            mesh.reversed_depth,
            mesh.outline_pass,
        );
        if let Some(result) = self.pipelines.get(&key) {
            return Ok(result.clone());
        }
        if self.pipelines.len() >= 512 {
            return Err(GraphError::new(
                "limitExceeded",
                "Material pipeline budget exceeded",
            ));
        }
        let result = super::mesh::prepare_external(device, material, mesh, format, samples)?;
        self.pipelines.insert(key, result.clone());
        Ok(result)
    }
    pub fn retain(&mut self, value: Key) -> Result<(), GraphError> {
        self.registry.retain(key(value)).map_err(Into::into)
    }
    pub fn live(&self) -> u64 {
        self.registry.live_allocations()
    }
    pub fn resolve(&self, value: Key) -> Result<&PreparedMaterial, ResourceError> {
        self.registry.resolve(key(value))
    }
    pub fn compile(
        &mut self,
        device: &wgpu::Device,
        resources: &mut ResourceStore,
        shaders: &mut ShaderStore,
        engine_layout: &wgpu::BindGroupLayout,
        description: Description,
        bytes: u64,
    ) -> Result<Key, GraphError> {
        if description.passes.len() != 1 || description.passes[0].kind != Kind::Material {
            return Err(GraphError::new(
                "invalidDescriptor",
                "A material requires one mesh shader description",
            ));
        }
        if self.live() >= 256
            || description.label.len() > 1024
            || description.resources.len() > 1024
            || description.inputs.len() > 1024
        {
            return Err(GraphError::new(
                "limitExceeded",
                "Material allocation exceeds its limits",
            ));
        }
        self.registry.check_capacity(bytes)?;
        let pass = &description.passes[0];
        let screen = pass.screen_space.unwrap_or(false);
        let prepared = scoped(device, &pass.name, || {
            if (!screen && pass.screen_target.is_some())
                || pass.screen_stage.is_some_and(|stage| !screen || stage > 1)
                || pass.name.is_empty()
                || pass.name.len() > 1024
                || (!screen && !pass.writes.is_empty())
                || !pass.after.is_empty()
                || pass.color.is_some()
                || pass.workgroups.is_some()
                || pass.entry_point.is_some()
                || pass.vertex_count.is_some()
                || pass.instance_count.is_some()
                || pass.sample_count.is_some()
                || (screen && pass.blend.is_some())
                || pass.bindings.iter().any(|b| {
                    b.group == 0
                        || b.kind == BindingKind::StorageReadWrite
                        || (b.kind == BindingKind::StorageTexture && (!screen || b.stages != [1]))
                })
            {
                return Err(GraphError::new(
                    "invalidDescriptor",
                    "Group 0 is reserved; only screen fragments may write storage textures",
                ));
            }
            let vertex = pass.vertex_entry_point.as_ref().ok_or_else(|| {
                GraphError::new("invalidDescriptor", "Missing vertex entry point")
            })?;
            let fragment = pass.fragment_entry_point.as_ref().ok_or_else(|| {
                GraphError::new("invalidDescriptor", "Missing fragment entry point")
            })?;
            let shader = shaders.resolve(key(pass.program))?;
            for (name, stage) in [(vertex, "vertex"), (fragment, "fragment")] {
                if !shader
                    .entry_points
                    .iter()
                    .any(|entry| &entry.name == name && entry.stage == stage)
                {
                    return Err(GraphError::new(
                        "invalidDescriptor",
                        "Mesh shader entry point does not match its stage",
                    ));
                }
            }
            let mut bindings = bindings::prepare(device, resources, pass)?;
            let screen_target = if let Some(target) = pass.screen_target {
                let texture = resources.graph_texture(key(target))?;
                if texture.dimension() != wgpu::TextureDimension::D2
                    || texture.format() != wgpu::TextureFormat::Rgba16Float
                    || !texture
                        .usage()
                        .contains(wgpu::TextureUsages::RENDER_ATTACHMENT)
                {
                    return Err(GraphError::new(
                        "invalidBinding",
                        "Screen targets require a 2D RGBA16F render attachment",
                    ));
                }
                bindings.use_resource(target, false, true)?;
                Some(texture.create_view(&wgpu::TextureViewDescriptor {
                    mip_level_count: Some(1),
                    usage: Some(wgpu::TextureUsages::RENDER_ATTACHMENT),
                    ..Default::default()
                }))
            } else {
                None
            };
            let declared: HashSet<_> = description.resources.iter().map(|r| r.key).collect();
            let inputs: HashSet<_> = description.inputs.iter().copied().collect();
            let reads: HashSet<_> = pass.reads.iter().copied().collect();
            let writes: HashSet<_> = pass.writes.iter().copied().collect();
            let bound: HashSet<_> = bindings.reads.union(&bindings.writes).copied().collect();
            if declared.len() != description.resources.len()
                || inputs.len() != description.inputs.len()
                || description.resources.iter().any(|r| r.label.len() > 1024)
                || declared != bound
                || inputs != bindings.reads
                || reads != bindings.reads
                || writes != bindings.writes
                || reads.len() != pass.reads.len()
                || writes.len() != pass.writes.len()
            {
                return Err(GraphError::new(
                    "accessMismatch",
                    "Material bindings must match their read and write declarations",
                ));
            }
            if screen && pass.requires_uv.unwrap_or(false) {
                return Err(GraphError::new(
                    "invalidDescriptor",
                    "Screen effects have no mesh attributes",
                ));
            }
            let mut layouts = vec![if screen {
                crate::renderer::effects::layout(device)
            } else {
                engine_layout.clone()
            }];
            for entries in bindings.layouts.iter().skip(1) {
                layouts.push(
                    device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                        label: Some(&pass.name),
                        entries,
                    }),
                );
            }
            let groups = bindings
                .resources
                .iter()
                .enumerate()
                .skip(1)
                .map(|(index, values)| {
                    let entries: Vec<_> = values
                        .iter()
                        .map(|(binding, resource)| wgpu::BindGroupEntry {
                            binding: *binding,
                            resource: resource.binding(),
                        })
                        .collect();
                    device.create_bind_group(&wgpu::BindGroupDescriptor {
                        label: Some(&pass.name),
                        layout: &layouts[index],
                        entries: &entries,
                    })
                })
                .collect();
            let layout_refs: Vec<_> = layouts.iter().map(Some).collect();
            let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some(&pass.name),
                bind_group_layouts: &layout_refs,
                ..Default::default()
            });
            let mut material = PreparedMaterial {
                shader: shader.module.clone(),
                layout,
                groups,
                vertex: vertex.clone(),
                fragment: fragment.clone(),
                requires_uv: pass.requires_uv.unwrap_or(false),
                blend: pass.blend,
                screen_stage: pass.screen_stage.unwrap_or(0),
                screen_target,
                screen_pipeline: None,
                resources: declared.into_iter().map(key).collect(),
                program: key(pass.program),
            };
            // Validate the complete mesh interface before publishing any ownership.
            if screen {
                material.screen_pipeline = Some(crate::renderer::effects::pipeline(
                    device,
                    &material.shader,
                    &material.layout,
                    &material.vertex,
                    &material.fragment,
                    wgpu::TextureFormat::Rgba16Float,
                ));
            } else {
                super::mesh::prepare_external(
                    device,
                    &material,
                    &Default::default(),
                    wgpu::TextureFormat::Rgba8UnormSrgb,
                    1,
                )?;
            }
            Ok(material)
        })?;
        let owned = prepared.resources.clone();
        let program = prepared.program;
        resources.retain_graph(&owned)?;
        if let Err(error) = shaders.retain_graph(&[program]) {
            resources.release_graph(device, &owned)?;
            return Err(error.into());
        }
        match self.registry.insert(prepared, bytes) {
            Ok(value) => Ok(key_value(value)),
            Err(error) => {
                resources.release_graph(device, &owned)?;
                shaders.release_graph(&[program])?;
                Err(error.into())
            }
        }
    }
    pub fn release(
        &mut self,
        device: &wgpu::Device,
        resources: &mut ResourceStore,
        shaders: &mut ShaderStore,
        value: Key,
    ) -> Result<(), GraphError> {
        if self.registry.references(key(value))? > 1 {
            self.registry.release(key(value))?;
            return Ok(());
        }
        let material = self.registry.resolve(key(value))?;
        resources.release_graph(device, &material.resources)?;
        shaders.release_graph(&[material.program])?;
        self.registry.release(key(value))?;
        self.registry.retire_completed(0);
        self.pipelines.retain(|(owner, ..), _| *owner != value);
        Ok(())
    }
}
