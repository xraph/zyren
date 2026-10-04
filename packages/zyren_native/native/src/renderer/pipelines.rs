use crate::scene::{Frame, Mesh};
use std::collections::{HashMap, HashSet};

const MAX_PIPELINES: usize = 512;
const MAX_PHYSICAL_LAYOUTS: usize = 128;

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub(super) struct PipelineKey {
    format: wgpu::TextureFormat,
    sample_count: u32,
    textured: bool,
    physical_maps: u64,
    lobes: u8,
    standard: bool,
    tangent: bool,
    colored: bool,
    instanced: bool,
    deformed: bool,
    side: u32,
    mirrored: bool,
    blend: bool,
    primitive_kind: u32,
    reversed_depth: bool,
    depth_equal: bool,
    depth_test: bool,
    depth_write: bool,
}
impl PipelineKey {
    pub(super) fn automatic(mut self, enabled: bool) -> Self {
        if enabled {
            self.instanced = true;
            self.mirrored = false;
        }
        self
    }
    pub(super) fn new(
        format: wgpu::TextureFormat,
        mesh: &Mesh,
        tangent: bool,
        sample_count: u32,
        mask: bool,
    ) -> Self {
        Self {
            format,
            sample_count,
            physical_maps: mesh
                .pbr
                .as_ref()
                .map_or(0, super::physical_maps::binding_key),
            lobes: active_lobes(mesh),
            colored: mesh.vertex_colors,
            instanced: mesh.instances != 0,
            deformed: mesh.pose != 0,
            textured: mesh.texture_maps().next().is_some(),
            tangent: tangent
                && mesh.pbr.is_some()
                && (mesh.texture_maps().next().is_some() || mesh.anisotropic()),
            standard: mesh.pbr.is_some(),
            side: mesh.side,
            mirrored: mesh.primitive_kind == 0
                && glam::Mat4::from_cols_array(&mesh.model).determinant() < 0.,
            blend: mesh.alpha_mode == 2,
            primitive_kind: mesh.primitive_kind,
            reversed_depth: mesh.reversed_depth,
            depth_equal: mask,
            depth_test: mesh.depth_test,
            depth_write: !mask && mesh.writes_depth(),
        }
    }
}
fn active_lobes(mesh: &Mesh) -> u8 {
    let Some(material) = &mesh.pbr else {
        return 0;
    };
    let Some(p) = material.physical else {
        return 0;
    };
    let coat = p[2] > 0.;
    let sheen = p[8..11].iter().any(|v| *v > 0.);
    let anisotropy = p[11] > 0.;
    let film = material.optical[0] > 0.
        && (material.optical[3] > 0.
            || (material.physical_maps[11].is_some() && material.optical[2] > 0.));
    let transmission = material.transmission[0] > 0.
        && (material.metallic < 1. || material.metallic_roughness_map.is_some());
    let dispersion = transmission && material.optical[4] > 0. && material.transmission[1] > 0.;
    1 | (u8::from(coat) << 1)
        | (u8::from(sheen) << 2)
        | (u8::from(anisotropy) << 3)
        | (u8::from(film) << 4)
        | (u8::from(transmission) << 5)
        | (u8::from(dispersion) << 6)
}

pub(super) struct MeshPipelines {
    shader: wgpu::ShaderModule,
    physical: HashMap<u64, super::physical_maps::Variant>,
    pbr_layout: wgpu::BindGroupLayout,
    standard_maps: wgpu::BindGroupLayout,
    deformation_layout: wgpu::BindGroupLayout,
    plain: wgpu::PipelineLayout,
    deformed_plain: wgpu::PipelineLayout,
    deformed_textured: wgpu::PipelineLayout,
    textured: wgpu::PipelineLayout,
    standard_plain: wgpu::PipelineLayout,
    deformed_standard_plain: wgpu::PipelineLayout,
    deformed_standard_textured: wgpu::PipelineLayout,
    standard_textured: wgpu::PipelineLayout,
    cache: HashMap<PipelineKey, wgpu::RenderPipeline>,
    limits: (usize, usize),
    retired_layouts: Vec<wgpu::BindGroupLayout>,
    #[cfg(test)]
    fail_creation_after: Option<usize>,
    #[cfg(test)]
    preparation_peak: (usize, usize),
}
impl MeshPipelines {
    pub(super) fn new(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        pbr_layout: &wgpu::BindGroupLayout,
        texture_layout: &wgpu::BindGroupLayout,
        standard_texture_layout: &wgpu::BindGroupLayout,
        deformation_layout: &wgpu::BindGroupLayout,
    ) -> Self {
        Self {
            physical: HashMap::new(),
            pbr_layout: pbr_layout.clone(),
            standard_maps: standard_texture_layout.clone(),
            deformation_layout: deformation_layout.clone(),
            shader: device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("native mesh materials"),
                source: wgpu::ShaderSource::Wgsl(shader_source(0).into()),
            }),
            deformed_plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("deformed triangles"),
                bind_group_layouts: &[Some(layout), None, Some(deformation_layout)],
                ..Default::default()
            }),
            deformed_textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("deformed triangles"),
                bind_group_layouts: &[Some(layout), Some(texture_layout), Some(deformation_layout)],
                ..Default::default()
            }),
            deformed_standard_plain: device.create_pipeline_layout(
                &wgpu::PipelineLayoutDescriptor {
                    label: Some("deformed triangles"),
                    bind_group_layouts: &[Some(pbr_layout), None, Some(deformation_layout)],
                    ..Default::default()
                },
            ),
            deformed_standard_textured: device.create_pipeline_layout(
                &wgpu::PipelineLayoutDescriptor {
                    label: Some("deformed triangles"),
                    bind_group_layouts: &[
                        Some(pbr_layout),
                        Some(standard_texture_layout),
                        Some(deformation_layout),
                    ],
                    ..Default::default()
                },
            ),
            plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[Some(layout)],
                ..Default::default()
            }),
            textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: None,
                bind_group_layouts: &[Some(layout), Some(texture_layout)],
                ..Default::default()
            }),
            standard_plain: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("standard material"),
                bind_group_layouts: &[Some(pbr_layout)],
                ..Default::default()
            }),
            standard_textured: device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                label: Some("textured standard material"),
                bind_group_layouts: &[Some(pbr_layout), Some(standard_texture_layout)],
                ..Default::default()
            }),
            cache: HashMap::new(),
            limits: (MAX_PIPELINES, MAX_PHYSICAL_LAYOUTS),
            retired_layouts: Vec::new(),
            #[cfg(test)]
            fail_creation_after: None,
            #[cfg(test)]
            preparation_peak: (0, 0),
        }
    }
    pub(super) fn prepare(
        &mut self,
        device: &wgpu::Device,
        frame: &Frame,
        requests: &[(wgpu::TextureFormat, u32, bool)],
        has_tangents: impl Fn(u32) -> bool,
        automatic: &HashSet<usize>,
    ) -> Result<(), String> {
        let (pipeline_limit, layout_limit) = self.limits;
        let required: HashSet<_> = requests
            .iter()
            .flat_map(|(format, samples, mask)| {
                frame
                    .meshes
                    .iter()
                    .enumerate()
                    .filter(|(_, mesh)| mesh.shader.is_none() && mesh.material_shader.is_none())
                    .map(|(index, mesh)| {
                        PipelineKey::new(
                            *format,
                            mesh,
                            has_tangents(mesh.geometry),
                            *samples,
                            *mask,
                        )
                        .automatic(!*mask && automatic.contains(&index))
                    })
            })
            .collect();
        let layouts: HashSet<_> = required
            .iter()
            .map(|key| key.physical_maps)
            .filter(|key| *key != 0)
            .collect();
        // Check every pass before touching the previous useful cache.
        if required.len() > pipeline_limit || layouts.len() > layout_limit {
            return Err(format!(
                "Built-in material working set needs {} pipelines and {} physical map layouts; limits are {pipeline_limit} and {layout_limit}",
                required.len(),
                layouts.len()
            ));
        }
        if required.iter().all(|key| self.cache.contains_key(key)) {
            return Ok(());
        }
        for mesh in &frame.meshes {
            let (textures, samplers) = super::physical_maps::binding_counts(
                mesh.pbr
                    .as_ref()
                    .map_or(0, super::physical_maps::binding_key),
            );
            if textures + 14 > device.limits().max_sampled_textures_per_shader_stage
                || samplers + 8 > device.limits().max_samplers_per_shader_stage
            {
                return Err(
                    "Physical maps exceed this adapter's texture or sampler binding limit".into(),
                );
            }
        }
        // Keep the useful cache intact until all candidates pass GPU scopes.
        // Preflight bounds candidates to one working set: at most another
        // 512 pipelines and 128 physical variants beside the resident cache.
        let mut staged_physical = HashMap::new();
        let mut staged_pipelines = HashMap::new();
        #[cfg(test)]
        {
            self.preparation_peak = (self.cache.len(), self.physical.len());
        }
        let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = device.push_error_scope(wgpu::ErrorFilter::Internal);
        #[cfg(test)]
        let mut created = 0;
        for &key in &required {
            if key.physical_maps != 0
                && !self.physical.contains_key(&key.physical_maps)
                && !staged_physical.contains_key(&key.physical_maps)
            {
                staged_physical.insert(
                    key.physical_maps,
                    super::physical_maps::Variant::new(
                        device,
                        key.physical_maps,
                        &self.pbr_layout,
                        &self.standard_maps,
                        &self.deformation_layout,
                    ),
                );
            }
            if !self.cache.contains_key(&key) {
                #[cfg(test)]
                let creation_key = if self.fail_creation_after == Some(created) {
                    self.fail_creation_after = None;
                    let mut invalid = key;
                    invalid.sample_count = 3;
                    invalid
                } else {
                    key
                };
                #[cfg(not(test))]
                let creation_key = key;
                #[cfg(test)]
                {
                    created += 1;
                }
                let variant = staged_physical
                    .get(&key.physical_maps)
                    .or_else(|| self.physical.get(&key.physical_maps));
                let pipeline = self.create(device, creation_key, variant);
                staged_pipelines.insert(key, pipeline);
                #[cfg(test)]
                {
                    self.preparation_peak = (
                        self.preparation_peak
                            .0
                            .max(self.cache.len() + staged_pipelines.len()),
                        self.preparation_peak
                            .1
                            .max(self.physical.len() + staged_physical.len()),
                    );
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
            // Dropping candidates also drops failed handles. Do not publish any
            // retirement delta or evict the previous frame's usable variants.
            return Err(error);
        }
        if self
            .cache
            .keys()
            .chain(required.iter())
            .copied()
            .collect::<HashSet<_>>()
            .len()
            > pipeline_limit
            || self
                .physical
                .keys()
                .chain(layouts.iter())
                .copied()
                .collect::<HashSet<_>>()
                .len()
                > layout_limit
        {
            self.cache.retain(|key, _| required.contains(key));
            self.physical.retain(|key, variant| {
                if layouts.contains(key) {
                    true
                } else {
                    self.retired_layouts.push(variant.maps.clone());
                    false
                }
            });
        }
        self.physical.extend(staged_physical);
        self.cache.extend(staged_pipelines);
        Ok(())
    }
    pub(super) fn take_retired_layouts(&mut self) -> Vec<wgpu::BindGroupLayout> {
        std::mem::take(&mut self.retired_layouts)
    }
    pub(super) fn get(&self, key: PipelineKey) -> &wgpu::RenderPipeline {
        &self.cache[&key]
    }
    pub(super) fn physical_layout(&self, mask: u64) -> &wgpu::BindGroupLayout {
        &self.physical[&mask].maps
    }
    pub(super) fn len(&self) -> usize {
        self.cache.len()
    }
    fn create(
        &self,
        device: &wgpu::Device,
        key: PipelineKey,
        variant: Option<&super::physical_maps::Variant>,
    ) -> wgpu::RenderPipeline {
        let attributes = wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3];
        let uv_attributes = wgpu::vertex_attr_array![2 => Float32x2, 3 => Float32x2];
        let color_attributes = wgpu::vertex_attr_array![5=>Float32x4,6=>Float32x4];
        let instance_attributes = wgpu::vertex_attr_array![6=>Float32x4,7=>Float32x4,8=>Float32x4,9=>Float32x4,10=>Float32x4,11=>Float32x4,12=>Float32x4,13=>Float32x3];
        let tangent_attributes = wgpu::vertex_attr_array![4 => Float32x4];
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
        if key.tangent {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: 16,
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: &tangent_attributes,
            }));
        }
        if key.colored {
            buffers.push(Some(wgpu::VertexBufferLayout {
                array_stride: if key.primitive_kind == 0 { 16 } else { 32 },
                step_mode: wgpu::VertexStepMode::Vertex,
                attributes: if key.primitive_kind == 0 {
                    &color_attributes[..1]
                } else {
                    &color_attributes
                },
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
            match (key.tangent, key.textured, key.colored) {
                (true, false, true) => "vs_instance_standard_tangent_colored_unmapped",
                (true, false, false) => "vs_instance_standard_tangent_unmapped",
                (true, _, true) => "vs_instance_standard_tangent_colored",
                (true, _, false) => "vs_instance_standard_tangent",
                (_, true, true) => "vs_instance_textured_colored",
                (_, true, false) => "vs_instance_textured",
                (_, _, true) => "vs_instance_colored",
                _ => "vs_instance_main",
            }
        } else if key.primitive_kind == 1 {
            if key.colored {
                "vs_line_colored"
            } else {
                "vs_line"
            }
        } else if key.primitive_kind == 2 {
            if key.colored {
                "vs_point_colored"
            } else {
                "vs_point"
            }
        } else if key.tangent && !key.textured {
            if key.colored {
                "vs_standard_tangent_colored_unmapped"
            } else {
                "vs_standard_tangent_unmapped"
            }
        } else if key.tangent {
            if key.colored {
                "vs_standard_tangent_colored"
            } else {
                "vs_standard_tangent"
            }
        } else if key.textured {
            if key.colored {
                "vs_textured_colored"
            } else {
                "vs_textured"
            }
        } else {
            if key.colored { "vs_colored" } else { "vs_main" }
        };
        let vertex_entry = if key.deformed {
            format!("deformed_{vertex_entry}")
        } else {
            vertex_entry.to_owned()
        };
        let shader = variant.map_or(&self.shader, |v| &v.shader);
        let constants: Vec<_> = [
            "PHYSICAL",
            "COAT",
            "SHEEN",
            "ANISOTROPY",
            "IRIDESCENCE",
            "TRANSMISSION",
            "DISPERSION",
        ]
        .into_iter()
        .enumerate()
        .map(|(bit, name)| (name, f64::from((key.lobes >> bit) & 1)))
        .collect();
        device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("native mesh state"),
            layout: Some(if let Some(variant) = variant {
                if key.deformed {
                    &variant.deformed
                } else {
                    &variant.plain
                }
            } else if key.deformed {
                if key.standard && key.textured {
                    &self.deformed_standard_textured
                } else if key.standard {
                    &self.deformed_standard_plain
                } else if key.textured {
                    &self.deformed_textured
                } else {
                    &self.deformed_plain
                }
            } else if key.standard && key.textured {
                &self.standard_textured
            } else if key.standard {
                &self.standard_plain
            } else if key.textured {
                &self.textured
            } else {
                &self.plain
            }),
            vertex: wgpu::VertexState {
                module: shader,
                entry_point: Some(&vertex_entry),
                compilation_options: Default::default(),
                buffers: &buffers,
            },
            fragment: Some(wgpu::FragmentState {
                module: shader,
                entry_point: Some(if key.primitive_kind != 0 {
                    "fs_primitive"
                } else if key.standard && key.textured {
                    "fs_standard_textured"
                } else if key.standard {
                    "fs_standard"
                } else if key.textured {
                    "fs_textured"
                } else {
                    "fs_main"
                }),
                compilation_options: wgpu::PipelineCompilationOptions {
                    constants: &constants,
                    ..Default::default()
                },
                targets: &[Some(wgpu::ColorTargetState {
                    format: key.format,
                    blend: if key.blend {
                        Some(wgpu::BlendState::ALPHA_BLENDING)
                    } else {
                        None
                    },
                    write_mask: wgpu::ColorWrites::ALL,
                })],
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
                depth_write_enabled: Some(key.depth_write),
                depth_compare: Some(if key.depth_test {
                    match (key.reversed_depth, key.depth_equal) {
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
                count: key.sample_count,
                ..Default::default()
            },
            multiview_mask: None,
            cache: None,
        })
    }
}

pub(super) fn shader_source(mask: u64) -> String {
    format!(
        "{}\n{}",
        concat!(
            include_str!("../mesh.wgsl"),
            "\n",
            include_str!("../deformation.wgsl"),
            "\n",
            include_str!("../deformation_mesh.wgsl"),
            "\n",
            include_str!("primitives.wgsl"),
            include_str!("coverage.wgsl"),
            "\n",
            include_str!("pbr.wgsl"),
            "\n",
            include_str!("physical.wgsl"),
            include_str!("iridescence.wgsl"),
            include_str!("transmission.wgsl"),
            "\n",
            include_str!("area_lights.wgsl"),
            "\n",
            include_str!("shadow_sampling.wgsl")
        ),
        super::physical_maps::shader(mask)
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn frame() -> Frame {
        serde_json::from_value(json!({
            "version": 1, "view_projection": glam::Mat4::IDENTITY.to_cols_array(),
            "background": [0,0,0], "light_direction": [0,0,1], "ambient": 0,
            "geometries": [], "meshes": []
        }))
        .unwrap()
    }

    fn physical() -> Mesh {
        let mut mesh = Mesh::default();
        mesh.pbr = Some(
            serde_json::from_value(json!({
                "metallic": 0, "roughness": 0.5, "emissive": [0,0,0],
                "physical": [1.5,1,0,0,1,1,1,1,0,0,0,0,0,1,1,0]
            }))
            .unwrap(),
        );
        mesh
    }

    #[test]
    fn lobe_keys_canonicalize_zero_factors_and_keep_mapped_metal_transmission() {
        let mut mesh = physical();
        assert_eq!(active_lobes(&mesh), 1);
        let map: crate::scene::ColorMap = serde_json::from_value(json!({
            "texture":1, "uv_set":0, "sampler":[0,0,0,0,0]
        }))
        .unwrap();
        let pbr = mesh.pbr.as_mut().unwrap();
        pbr.physical_maps = std::array::from_fn(|_| Some(map.clone()));
        assert_eq!(active_lobes(&mesh), 1);
        let pbr = mesh.pbr.as_mut().unwrap();
        pbr.metallic = 1.;
        pbr.transmission[0] = 1.;
        assert_eq!(active_lobes(&mesh), 1);
        mesh.pbr.as_mut().unwrap().metallic_roughness_map = Some(map);
        assert_ne!(active_lobes(&mesh) & 32, 0);
        let pbr = mesh.pbr.as_mut().unwrap();
        pbr.optical = [1., 1.3, 100., 0., 0., 0., 0., 0.];
        assert_ne!(active_lobes(&mesh) & 16, 0);
        mesh.pbr.as_mut().unwrap().physical_maps[11] = None;
        assert_eq!(active_lobes(&mesh) & 16, 0);
    }

    #[test]
    #[ignore = "requires a native GPU"]
    fn creation_failure_preserves_full_cache_and_valid_key_retry() {
        let mut renderer = pollster::block_on(super::super::Renderer::new()).unwrap();
        let state = renderer.state.as_mut().unwrap();
        let pipelines = &mut state.pipelines;
        pipelines.limits = (3, 1);
        let requests = [(wgpu::TextureFormat::Rgba8Unorm, 1, false)];
        let scene = |slot| {
            let mut frame = frame();
            frame.meshes = (0..3)
                .map(|side| {
                    let mut mesh = physical();
                    mesh.side = side;
                    mesh.pbr.as_mut().unwrap().physical_maps[slot] = Some(
                        serde_json::from_value(json!({
                            "texture": 1, "uv_set": 0, "sampler": [0,0,0,0,0]
                        }))
                        .unwrap(),
                    );
                    mesh
                })
                .collect();
            frame
        };
        let old = scene(0);
        pipelines
            .prepare(&state.device, &old, &requests, |_| false, &HashSet::new())
            .unwrap();
        let handles = pipelines.cache.clone();
        let (&old_key, old_variant) = pipelines.physical.iter().next().unwrap();
        let old_layout = old_variant.maps.clone();
        let mut next = scene(1);
        next.meshes.truncate(1);
        let joint = [
            requests[0],
            (wgpu::TextureFormat::Rgba16Float, 4, false),
            (wgpu::TextureFormat::Rgba8Unorm, 1, true),
        ];
        // Force a real wgpu validation error after one successful candidate.
        // The requested keys remain valid, so retry must create fresh handles.
        pipelines.fail_creation_after = Some(1);
        let error = pipelines
            .prepare(&state.device, &next, &joint, |_| false, &HashSet::new())
            .unwrap_err();
        assert!(error.to_lowercase().contains("sample"), "{error}");
        assert_eq!(pipelines.fail_creation_after, None);
        assert_eq!(pipelines.preparation_peak, (6, 2));
        assert_eq!(pipelines.cache.len(), handles.len());
        for (key, handle) in &handles {
            assert_eq!(pipelines.cache.get(key), Some(handle));
        }
        assert_eq!(pipelines.physical.len(), 1);
        assert_eq!(pipelines.physical_layout(old_key), &old_layout);
        assert!(pipelines.take_retired_layouts().is_empty());
        pipelines
            .prepare(&state.device, &old, &requests, |_| false, &HashSet::new())
            .unwrap();
        for (key, handle) in &handles {
            assert_eq!(pipelines.cache.get(key), Some(handle));
        }
        pipelines
            .prepare(&state.device, &next, &joint, |_| false, &HashSet::new())
            .unwrap();
        assert_eq!(pipelines.cache.len(), 3);
        assert_eq!(pipelines.physical.len(), 1);
        assert!(handles.keys().all(|key| !pipelines.cache.contains_key(key)));
        assert_eq!(pipelines.take_retired_layouts(), vec![old_layout]);
        let validation = state.device.push_error_scope(wgpu::ErrorFilter::Validation);
        for (format, samples, mask) in joint {
            let key = PipelineKey::new(format, &next.meshes[0], false, samples, mask);
            let pipeline = pipelines.get(key);
            let texture = |format| {
                state.device.create_texture(&wgpu::TextureDescriptor {
                    label: Some("pipeline retry validation"),
                    size: wgpu::Extent3d {
                        width: 4,
                        height: 4,
                        depth_or_array_layers: 1,
                    },
                    mip_level_count: 1,
                    sample_count: samples,
                    dimension: wgpu::TextureDimension::D2,
                    format,
                    usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                    view_formats: &[],
                })
            };
            let color = texture(format);
            let depth = texture(wgpu::TextureFormat::Depth32Float);
            let color_view = color.create_view(&Default::default());
            let depth_view = depth.create_view(&Default::default());
            let mut encoder = state.device.create_command_encoder(&Default::default());
            {
                let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                    label: Some("retry pipeline handles"),
                    color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                        view: &color_view,
                        depth_slice: None,
                        resolve_target: None,
                        ops: wgpu::Operations {
                            load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                            store: wgpu::StoreOp::Discard,
                        },
                    })],
                    depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                        view: &depth_view,
                        depth_ops: Some(wgpu::Operations {
                            load: wgpu::LoadOp::Clear(1.),
                            store: wgpu::StoreOp::Discard,
                        }),
                        stencil_ops: None,
                    }),
                    timestamp_writes: None,
                    occlusion_query_set: None,
                    multiview_mask: None,
                });
                // Encoding validates the actual returned handle, without a
                // synthetic draw that would need unrelated material resources.
                pass.set_pipeline(pipeline);
            }
            state.queue.submit([encoder.finish()]);
        }
        state
            .device
            .poll(wgpu::PollType::wait_indefinitely())
            .unwrap();
        assert!(pollster::block_on(validation.pop()).is_none());
    }

    #[test]
    #[ignore = "requires a native GPU"]
    fn pipeline_cache_churn_and_complete_working_set_rejection_preserve_retry() {
        let mut renderer = pollster::block_on(super::super::Renderer::new()).unwrap();
        let state = renderer.state.as_mut().unwrap();
        let pipelines = &mut state.pipelines;
        assert_eq!(pipelines.limits, (512, 128));
        // Exercise production eviction with a small GPU working set.
        pipelines.limits = (4, 2);
        let requests = [(wgpu::TextureFormat::Rgba8Unorm, 1, false)];
        let mut frame = frame();
        let mut last = None;
        for i in 0..12 {
            let mut mesh = physical();
            mesh.side = i % 3;
            mesh.depth_test = i & 1 != 0;
            mesh.depth_write = Some(i & 2 != 0);
            frame.meshes = vec![mesh];
            pipelines
                .prepare(&state.device, &frame, &requests, |_| false, &HashSet::new())
                .unwrap();
            assert!(pipelines.len() <= 4);
            let key = PipelineKey::new(requests[0].0, &frame.meshes[0], false, 1, false);
            assert!(pipelines.cache.contains_key(&key));
            last = Some((frame.clone(), key, pipelines.get(key).clone()));
        }
        let (valid, key, handle) = last.unwrap();
        let before = pipelines.len();
        frame.meshes = (0..5)
            .map(|i| {
                let mut mesh = physical();
                mesh.side = i % 3;
                mesh.depth_test = i > 2;
                mesh
            })
            .collect();
        let error = pipelines
            .prepare(&state.device, &frame, &requests, |_| false, &HashSet::new())
            .unwrap_err();
        assert!(error.contains("needs 5 pipelines"), "{error}");
        assert_eq!(pipelines.len(), before);
        assert_eq!(pipelines.get(key), &handle);
        pipelines
            .prepare(&state.device, &valid, &requests, |_| false, &HashSet::new())
            .unwrap();
        assert_eq!(pipelines.get(key), &handle);
        // Churn actual physical map modules and retire their cached layouts.
        pipelines.limits = (4, 2);
        for slot in 0..4 {
            let mut mesh = physical();
            mesh.pbr.as_mut().unwrap().physical_maps[slot] = Some(
                serde_json::from_value(json!({
                    "texture": 1, "uv_set": 0, "sampler": [0,0,0,0,0]
                }))
                .unwrap(),
            );
            frame.meshes = vec![mesh];
            pipelines
                .prepare(&state.device, &frame, &requests, |_| false, &HashSet::new())
                .unwrap();
            assert!(pipelines.physical.len() <= 2);
            assert!(pipelines.len() <= 4);
        }
        assert!(!pipelines.take_retired_layouts().is_empty());
        pipelines
            .prepare(&state.device, &valid, &requests, |_| false, &HashSet::new())
            .unwrap();
        let handle = pipelines.get(key).clone();
        // Outline and main passes jointly exceed the cap, even when each fits.
        pipelines.limits = (1, 2);
        assert!(
            pipelines
                .prepare(
                    &state.device,
                    &valid,
                    &[requests[0], (wgpu::TextureFormat::Rgba8Unorm, 1, true)],
                    |_| false,
                    &HashSet::new()
                )
                .unwrap_err()
                .contains("needs 2 pipelines")
        );
        assert_eq!(pipelines.get(key), &handle);
    }
}
