use super::{GraphError, bindings, descriptor::*, key, key_value, scoped};
use crate::{
    resources::{
        ResourceError, ResourceStore,
        registry::{ResourceKey, ResourceRegistry, next_registry_id},
    },
    shaders::ShaderStore,
};
use std::collections::HashSet;

pub(crate) struct PreparedMaterial {
    pub shader: wgpu::ShaderModule,
    pub layout: wgpu::PipelineLayout,
    pub groups: Vec<wgpu::BindGroup>,
    pub vertex: String,
    pub fragment: String,
    pub requires_uv: bool,
    pub screen_pipeline: Option<wgpu::RenderPipeline>,
    resources: Vec<ResourceKey>,
    program: ResourceKey,
}
pub(crate) struct MaterialStore {
    registry: ResourceRegistry<PreparedMaterial>,
}
impl Default for MaterialStore {
    fn default() -> Self {
        Self {
            registry: ResourceRegistry::new(next_registry_id(), 1, 8 * 1024 * 1024),
        }
    }
}
impl MaterialStore {
    pub fn retain(&mut self, value: Key) -> Result<(), GraphError> {
        self.registry.retain(key(value)).map_err(Into::into)
    }
    pub fn live(&self) -> u64 {
        self.registry.live_allocations()
    }
    pub fn contains(&self, value: Key) -> bool {
        self.registry.resolve(key(value)).is_ok()
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
        let prepared = scoped(device, &pass.name, || {
            if pass.name.is_empty()
                || pass.name.len() > 1024
                || !pass.writes.is_empty()
                || !pass.after.is_empty()
                || pass.color.is_some()
                || pass.workgroups.is_some()
                || pass.entry_point.is_some()
                || pass.vertex_count.is_some()
                || pass.instance_count.is_some()
                || pass.sample_count.is_some()
                || pass.blend.is_some()
                || pass.bindings.iter().any(|b| {
                    b.group == 0
                        || matches!(
                            b.kind,
                            BindingKind::StorageReadWrite | BindingKind::StorageTexture
                        )
                })
            {
                return Err(GraphError::new(
                    "invalidDescriptor",
                    "Mesh shaders reserve group 0 and allow readonly user bindings",
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
            let bindings = bindings::prepare(device, resources, pass)?;
            let declared: HashSet<_> = description.resources.iter().map(|r| r.key).collect();
            let inputs: HashSet<_> = description.inputs.iter().copied().collect();
            let reads: HashSet<_> = pass.reads.iter().copied().collect();
            if declared.len() != description.resources.len()
                || description.resources.iter().any(|r| r.label.len() > 1024)
                || declared != bindings.reads
                || inputs != declared
                || reads != declared
                || !bindings.writes.is_empty()
            {
                return Err(GraphError::new(
                    "accessMismatch",
                    "Mesh bindings must match their resource declarations",
                ));
            }
            let screen = pass.screen_space.unwrap_or(false);
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
                crate::renderer::pipelines::material_pipeline(
                    device,
                    &material,
                    wgpu::TextureFormat::Rgba8UnormSrgb,
                    &Default::default(),
                    1,
                    false,
                );
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
        Ok(())
    }
}
