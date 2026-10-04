use super::{
    GraphError, GraphStore, Pipeline, PipelineKey, PipelineKind, PreparedPass, ScopedGraph,
    ShaderStore, bindings, descriptor::*, key, scoped,
};
use crate::resources::ResourceStore;
use std::{
    collections::{HashMap, HashSet},
    sync::{Arc, Weak},
};

type PreparedGraph = (
    Vec<PreparedPass>,
    Vec<super::ResourceKey>,
    Vec<super::ResourceKey>,
);

impl GraphStore {
    pub(super) fn compile(
        &mut self,
        device: &wgpu::Device,
        resources: &mut ResourceStore,
        shaders: &mut ShaderStore,
        description: Description,
        bytes: u64,
    ) -> Result<[u64; 4], GraphError> {
        if self.registry.live_allocations() >= 32
            || description.passes.is_empty()
            || description.passes.len() > 128
            || description.inputs.len() > 1024
            || description.resources.len() > 1024
            || description.label.len() > 1024
        {
            return Err(GraphError::new(
                "limitExceeded",
                "Graph exceeds pass, resource, label or live graph limits",
            ));
        }
        self.registry.check_capacity(bytes)?;
        if description.scene_pass_index > description.passes.len()
            || (description.scene_pass_index > 0 && description.scene_color.is_none())
        {
            return Err(GraphError::new(
                "invalidDescriptor",
                "Invalid scene pass boundary",
            ));
        }
        self.cache.retain(|_, value| value.strong_count() > 0);
        let frame = self.prepare_frame(resources, &description)?;
        let result = self.prepare(device, resources, shaders, &description);
        self.cache.retain(|_, value| value.strong_count() > 0);
        let (passes, resource_keys, shader_keys) = result?;
        resources.retain_graph(&resource_keys)?;
        if let Err(error) = shaders.retain_graph(&shader_keys) {
            resources.release_graph(device, &resource_keys)?;
            return Err(error.into());
        }
        let graph = Arc::new(ScopedGraph {
            scene_pass_index: description.scene_pass_index,
            passes,
            resources: resource_keys.clone(),
            shaders: shader_keys.clone(),
            frame,
            scene_resource: description.scene_color.map(key),
        });
        match self.registry.insert(graph, bytes) {
            Ok(key) => Ok(super::key_value(key)),
            Err(error) => {
                resources.release_graph(device, &resource_keys)?;
                shaders.release_graph(&shader_keys)?;
                Err(error.into())
            }
        }
    }

    fn prepare(
        &mut self,
        device: &wgpu::Device,
        resources: &ResourceStore,
        shaders: &ShaderStore,
        description: &Description,
    ) -> Result<PreparedGraph, GraphError> {
        let mut resource_labels = HashMap::new();
        for resource in &description.resources {
            if resource.label.len() > 1024
                || resource_labels
                    .insert(resource.key, resource.label.as_str())
                    .is_some()
            {
                return Err(GraphError::new(
                    "invalidDescriptor",
                    "Duplicate resource identity or oversized label",
                ));
            }
        }
        let declared_resources: HashSet<Key> = resource_labels.keys().copied().collect();
        let mut initialized: HashSet<Key> = description.inputs.iter().copied().collect();
        if !declared_resources.is_superset(&initialized) {
            return Err(GraphError::new(
                "invalidDescriptor",
                "Input resource is absent from resource table",
            ));
        }
        let mut names = HashSet::new();
        let mut passes = Vec::new();
        let mut shader_keys = HashSet::new();
        for (index, pass) in description.passes.iter().enumerate() {
            if index == description.scene_pass_index
                && let Some(scene) = description.scene_color
            {
                initialized.insert(scene);
            }
            if pass.scene_inputs.is_some()
                || pass.screen_target.is_some()
                || pass.screen_stage.is_some()
                || pass.screen_space.is_some()
            {
                return Err(GraphError::new(
                    "invalidDescriptor",
                    "Screen fields require a material",
                ));
            }
            if pass.name.is_empty() || pass.name.len() > 1024 || !names.insert(pass.name.clone()) {
                return Err(GraphError::new(
                    "duplicatePass",
                    "Pass names must be unique and within 1024 bytes",
                )
                .at(&pass.name));
            }
            if pass.reads.len() > 1024 || pass.writes.len() > 1024 || pass.after.len() > 128 {
                return Err(GraphError::new(
                    "limitExceeded",
                    "Pass access declarations exceed graph limits",
                )
                .at(&pass.name));
            }
            if pass
                .after
                .iter()
                .any(|name| name == &pass.name || !names.contains(name))
            {
                return Err(GraphError::new(
                    "missingDependency",
                    "Pass dependency must precede this pass",
                )
                .at(&pass.name));
            }
            let shader = shaders
                .resolve(key(pass.program))
                .map_err(GraphError::from)
                .map_err(|e| e.at(&pass.name))?;
            shader_keys.insert(key(pass.program));
            let mut pass_writes = HashSet::new();
            let prepared = scoped(device, &pass.name, || {
                let mut bindings = bindings::prepare(device, resources, pass)?;
                let mut color = None;
                let mut format = None;
                let mut workgroups = [0; 3];
                let mut vertex_count = 0;
                let mut instance_count = 0;
                let (vertex, fragment, compute) = match pass.kind {
                    Kind::Material => {
                        return Err(GraphError::new(
                            "invalidDescriptor",
                            "Use the material compiler for mesh shaders",
                        ));
                    }
                    Kind::Compute => {
                        if pass.color.is_some()
                            || pass.vertex_entry_point.is_some()
                            || pass.fragment_entry_point.is_some()
                            || pass.vertex_count.is_some()
                            || pass.instance_count.is_some()
                            || pass.sample_count.is_some()
                            || pass.blend.is_some()
                        {
                            return Err(GraphError::new(
                                "invalidDescriptor",
                                "Unexpected render fields on compute pass",
                            ));
                        }
                        workgroups = pass.workgroups.ok_or_else(|| {
                            GraphError::new("invalidDescriptor", "Missing workgroups")
                        })?;
                        if workgroups.iter().any(|n| {
                            *n == 0 || *n > device.limits().max_compute_workgroups_per_dimension
                        }) {
                            return Err(GraphError::new(
                                "limitExceeded",
                                "Dispatch exceeds device workgroup count",
                            ));
                        }
                        let entry = pass.entry_point.as_deref().ok_or_else(|| {
                            GraphError::new("invalidDescriptor", "Missing compute entry point")
                        })?;
                        check_entry(shader, entry, "compute")?;
                        ("", "", entry)
                    }
                    Kind::Render => {
                        if pass.entry_point.is_some()
                            || pass.workgroups.is_some()
                            || pass.sample_count != Some(1)
                        {
                            return Err(GraphError::new(
                                "unsupportedFeature",
                                "Render pass requires one sample and no compute fields",
                            ));
                        }
                        let target = pass.color.as_ref().ok_or_else(|| {
                            GraphError::new("invalidDescriptor", "Missing color attachment")
                        })?;
                        let texture = resources.graph_texture(key(target.key))?;
                        if !texture
                            .usage()
                            .contains(wgpu::TextureUsages::RENDER_ATTACHMENT)
                            || texture.dimension() != wgpu::TextureDimension::D2
                            || target.mip_level >= texture.mip_level_count()
                            || target
                                .clear
                                .iter()
                                .any(|n| !n.is_finite() || n.abs() > f32::MAX as f64)
                        {
                            return Err(GraphError::new(
                                "invalidBinding",
                                "Invalid color attachment usage, mip or clear color",
                            ));
                        }
                        bindings.use_resource(target.key, target.load == Load::Load, true)?;
                        format = Some(texture.format());
                        color = Some((
                            texture.create_view(&wgpu::TextureViewDescriptor {
                                base_mip_level: target.mip_level,
                                mip_level_count: Some(1),
                                usage: Some(wgpu::TextureUsages::RENDER_ATTACHMENT),
                                ..Default::default()
                            }),
                            wgpu::Operations {
                                load: if target.load == Load::Load {
                                    wgpu::LoadOp::Load
                                } else {
                                    wgpu::LoadOp::Clear(wgpu::Color {
                                        r: target.clear[0],
                                        g: target.clear[1],
                                        b: target.clear[2],
                                        a: target.clear[3],
                                    })
                                },
                                store: if target.store == Store::Store {
                                    wgpu::StoreOp::Store
                                } else {
                                    wgpu::StoreOp::Discard
                                },
                            },
                        ));
                        vertex_count = pass.vertex_count.ok_or_else(|| {
                            GraphError::new("invalidDescriptor", "Missing vertex count")
                        })?;
                        instance_count = pass.instance_count.ok_or_else(|| {
                            GraphError::new("invalidDescriptor", "Missing instance count")
                        })?;
                        if vertex_count == 0
                            || vertex_count > 1048576
                            || instance_count == 0
                            || instance_count > 65535
                        {
                            return Err(GraphError::new(
                                "limitExceeded",
                                "Procedural draw exceeds count limits",
                            ));
                        }
                        let vertex = pass.vertex_entry_point.as_deref().ok_or_else(|| {
                            GraphError::new("invalidDescriptor", "Missing vertex entry point")
                        })?;
                        let fragment = pass.fragment_entry_point.as_deref().ok_or_else(|| {
                            GraphError::new("invalidDescriptor", "Missing fragment entry point")
                        })?;
                        check_entry(shader, vertex, "vertex")?;
                        check_entry(shader, fragment, "fragment")?;
                        (vertex, fragment, "")
                    }
                };
                if pass.reads.iter().copied().collect::<HashSet<_>>() != bindings.reads
                    || pass.writes.iter().copied().collect::<HashSet<_>>() != bindings.writes
                {
                    return Err(GraphError::new(
                        "accessMismatch",
                        "Declared reads/writes differ from typed bindings",
                    ));
                }
                if !declared_resources.is_superset(&bindings.reads)
                    || !declared_resources.is_superset(&bindings.writes)
                {
                    return Err(GraphError::new(
                        "invalidDescriptor",
                        "Pass references resource absent from table",
                    ));
                }
                if index < description.scene_pass_index
                    && description.scene_color.is_some_and(|scene| {
                        bindings.reads.contains(&scene) || bindings.writes.contains(&scene)
                    })
                {
                    return Err(GraphError::new(
                        "invalidDescriptor",
                        "Before-scene passes cannot access scene color",
                    ));
                }
                if let Some(missing) = bindings.reads.difference(&initialized).next() {
                    let mut error = GraphError::new(
                        "uninitializedRead",
                        "Resource is read before initialization or after discard",
                    );
                    error.resource_label = resource_labels.get(missing).map(|s| (*s).to_owned());
                    return Err(error);
                }
                pass_writes = bindings.writes;
                let cache_key = PipelineKey {
                    module: shader.module.clone(),
                    bindings: bindings.keys,
                    vertex: vertex.to_owned(),
                    fragment: fragment.to_owned(),
                    compute: compute.to_owned(),
                    format,
                    blend: pass.blend.unwrap_or_default(),
                };
                let pipeline = if let Some(pipeline) =
                    self.cache.get(&cache_key).and_then(Weak::upgrade)
                {
                    self.cache_hits = self.cache_hits.saturating_add(1);
                    pipeline
                } else {
                    self.compilation_count = self.compilation_count.saturating_add(1);
                    let layouts: Vec<_> = bindings
                        .layouts
                        .iter()
                        .map(|entries| {
                            device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
                                label: Some(&pass.name),
                                entries,
                            })
                        })
                        .collect();
                    let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                        label: Some(&pass.name),
                        bind_group_layouts: &layouts.iter().map(Some).collect::<Vec<_>>(),
                        immediate_size: 0,
                    });
                    let kind = if pass.kind == Kind::Compute {
                        PipelineKind::Compute(device.create_compute_pipeline(
                            &wgpu::ComputePipelineDescriptor {
                                label: Some(&pass.name),
                                layout: Some(&layout),
                                module: &shader.module,
                                entry_point: Some(compute),
                                compilation_options: Default::default(),
                                cache: None,
                            },
                        ))
                    } else {
                        PipelineKind::Render(device.create_render_pipeline(
                            &wgpu::RenderPipelineDescriptor {
                                label: Some(&pass.name),
                                layout: Some(&layout),
                                vertex: wgpu::VertexState {
                                    module: &shader.module,
                                    entry_point: Some(vertex),
                                    compilation_options: Default::default(),
                                    buffers: &[],
                                },
                                fragment: Some(wgpu::FragmentState {
                                    module: &shader.module,
                                    entry_point: Some(fragment),
                                    compilation_options: Default::default(),
                                    targets: &[Some(wgpu::ColorTargetState {
                                        format: format.unwrap(),
                                        blend: pass.blend.unwrap_or_default().state(),
                                        write_mask: wgpu::ColorWrites::ALL,
                                    })],
                                }),
                                primitive: Default::default(),
                                depth_stencil: None,
                                multisample: Default::default(),
                                multiview_mask: None,
                                cache: None,
                            },
                        ))
                    };
                    Arc::new(Pipeline { kind, layouts })
                };
                let groups = bindings
                    .resources
                    .iter()
                    .zip(&pipeline.layouts)
                    .map(|(resources, layout)| {
                        let entries: Vec<_> = resources
                            .iter()
                            .map(|(binding, resource)| wgpu::BindGroupEntry {
                                binding: *binding,
                                resource: resource.binding(),
                            })
                            .collect();
                        device.create_bind_group(&wgpu::BindGroupDescriptor {
                            label: Some(&pass.name),
                            layout,
                            entries: &entries,
                        })
                    })
                    .collect();
                Ok((
                    cache_key,
                    PreparedPass {
                        name: pass.name.clone(),
                        pipeline,
                        groups,
                        color,
                        workgroups,
                        vertex_count,
                        instance_count,
                    },
                ))
            })?;
            self.cache
                .insert(prepared.0, Arc::downgrade(&prepared.1.pipeline));
            initialized.extend(pass_writes);
            if let Some(color) = &pass.color
                && color.store == Store::Discard
            {
                initialized.remove(&color.key);
            }
            passes.push(prepared.1);
        }
        if description.scene_pass_index == description.passes.len()
            && let Some(scene) = description.scene_color
        {
            initialized.insert(scene);
        }
        if let Some(output) = description.output
            && !initialized.contains(&output)
        {
            return Err(GraphError::new(
                "uninitializedRead",
                "Frame output is uninitialized or discarded",
            ));
        }
        let mut resource_keys: Vec<_> = declared_resources.into_iter().map(key).collect();
        resource_keys.sort_by_key(|k| (k.renderer, k.device_generation, k.slot, k.slot_generation));
        Ok((passes, resource_keys, shader_keys.into_iter().collect()))
    }
}

pub(super) fn check_entry(
    shader: &crate::shaders::CompiledShader,
    name: &str,
    stage: &str,
) -> Result<(), GraphError> {
    if shader
        .entry_points
        .iter()
        .any(|entry| entry.name == name && entry.stage == stage)
    {
        Ok(())
    } else {
        Err(GraphError::new(
            "invalidDescriptor",
            "Shader entry point does not match pass stage",
        ))
    }
}
