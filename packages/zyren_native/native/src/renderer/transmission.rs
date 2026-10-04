use super::Renderer;
use crate::{
    render_graph::{FrameGraph, PreparedMaterial},
    scene::Frame,
};

pub(super) struct Targets {
    pub color: wgpu::TextureView,
    pub depth: wgpu::TextureView,
    pub(super) size: [u32; 2],
    pub format: wgpu::TextureFormat,
    pub samples: u32,
    pub seed: Option<(wgpu::RenderPipeline, wgpu::BindGroup)>,
    pub multisample: Option<super::multisample::Multisample>,
    pub depth_resolve: Option<wgpu::RenderPipeline>,
    reversed_depth: bool,
    bytes: u64,
    owner: u64,
}
pub(super) struct System {
    pub targets: Option<Targets>,
    pub materials: Vec<Option<PreparedMaterial>>,
    defaults: [wgpu::TextureView; 2],
    #[cfg(test)]
    pub disable_reuse: bool,
}
fn texture(
    device: &wgpu::Device,
    format: wgpu::TextureFormat,
    size: [u32; 2],
) -> wgpu::TextureView {
    device
        .create_texture(&wgpu::TextureDescriptor {
            label: Some("opaque transmission capture"),
            size: wgpu::Extent3d {
                width: size[0],
                height: size[1],
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        })
        .create_view(&Default::default())
}
impl System {
    pub fn new(device: &wgpu::Device) -> Self {
        Self {
            targets: None,
            #[cfg(test)]
            disable_reuse: false,
            materials: Vec::new(),
            defaults: [
                texture(device, wgpu::TextureFormat::Rgba8Unorm, [1, 1]),
                texture(device, wgpu::TextureFormat::Depth32Float, [1, 1]),
            ],
        }
    }
    fn retire_targets(&mut self, cache: &mut super::draw_cache::Cache) {
        if let Some(targets) = self.targets.take() {
            cache.invalidate_textures(&[targets.color.texture(), targets.depth.texture()]);
        }
    }
    pub fn remove(&mut self, view: u64, cache: &mut super::draw_cache::Cache) {
        if self.targets.as_ref().is_some_and(|t| t.owner == view) {
            self.retire_targets(cache);
            self.materials.clear();
        }
    }
    pub fn bytes(&self) -> u64 {
        self.targets.as_ref().map_or(0, |t| t.bytes)
    }
    pub fn entries(&self, capture: bool) -> [wgpu::BindGroupEntry<'_>; 2] {
        let targets = self.targets.as_ref().filter(|_| !capture);
        let views = targets.map_or([&self.defaults[0], &self.defaults[1]], |t| {
            [&t.color, &t.depth]
        });
        std::array::from_fn(|i| wgpu::BindGroupEntry {
            binding: 13 + i as u32,
            resource: wgpu::BindingResource::TextureView(views[i]),
        })
    }
}
pub(super) fn layout_entries() -> Vec<wgpu::BindGroupLayoutEntry> {
    [
        wgpu::TextureSampleType::Float { filterable: false },
        wgpu::TextureSampleType::Depth,
    ]
    .into_iter()
    .enumerate()
    .map(|(i, sample_type)| wgpu::BindGroupLayoutEntry {
        binding: 13 + i as u32,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Texture {
            sample_type,
            view_dimension: wgpu::TextureViewDimension::D2,
            multisampled: false,
        },
        count: None,
    })
    .collect()
}
impl Renderer {
    pub(super) fn reuse_opaque_capture(
        &self,
        frame: &Frame,
        format: wgpu::TextureFormat,
        load_depth: bool,
    ) -> bool {
        #[cfg(test)]
        if self.transmission.disable_reuse {
            return false;
        }
        let Some(targets) = &self.transmission.targets else {
            return false;
        };
        if frame.settings.opaque_capture_scale != 1.
            || load_depth
            || targets.format != format
            || targets.samples != 1
            || frame.sample_count() != 1
        {
            return false;
        }
        let mut barrier = false;
        let mut opaque = false;
        for draw in &self.batches.order {
            if self.batches.skipped.contains(&draw.mesh) {
                continue;
            }
            let mesh = &frame.meshes[draw.mesh];
            if mesh.requires_opaque_capture() || mesh.alpha_mode == 2 {
                barrier = true;
            } else {
                if barrier {
                    return false;
                }
                opaque = true;
            }
        }
        opaque
    }
    pub(super) fn prepare_transmission(
        &mut self,
        frame: &Frame,
        format: wgpu::TextureFormat,
        size: [u32; 2],
        graph: Option<&FrameGraph>,
    ) -> Result<(), String> {
        if !frame
            .meshes
            .iter()
            .any(|m| m.color_visible && m.requires_opaque_capture())
        {
            let state = self.state.as_mut().unwrap();
            state
                .transmission
                .retire_targets(&mut state.draw_cache.borrow_mut());
            state.transmission.materials.clear();
            return Ok(());
        }
        let size = size.map(|n| {
            ((n as f64 * f64::from(frame.settings.opaque_capture_scale)).ceil() as u32).max(1)
        });
        let scene_inputs = frame
            .meshes
            .iter()
            .any(|m| m.color_visible && m.scene_inputs);
        let format = if scene_inputs {
            wgpu::TextureFormat::Rgba16Float
        } else {
            format
        };
        let samples = if scene_inputs {
            frame.sample_count()
        } else {
            1
        };
        let reversed_depth = frame.settings.reversed_depth();
        let owner = frame.binary.as_ref().map_or(0, |b| b.view);
        let reuse = self.transmission.targets.as_ref().is_some_and(|t| {
            t.size == size
                && t.format == format
                && t.samples == samples
                && t.reversed_depth == reversed_depth
        });
        let bytes = allocation_at_samples(
            format,
            size,
            samples,
            if reuse { 0 } else { self.transmission.bytes() },
        )?;
        let materials = self.prepare_materials_in_format(frame, format, graph, samples, false)?;
        if !reuse {
            let validation = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
            let memory = self.device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
            let internal = self.device.push_error_scope(wgpu::ErrorFilter::Internal);
            let color = texture(&self.device, format, size);
            let depth = texture(&self.device, wgpu::TextureFormat::Depth32Float, size);
            let seed = (samples == 1).then(|| seed(&self.device, format, &color, &depth));
            let candidate = Targets {
                color,
                depth,
                seed,
                size,
                format,
                samples,
                multisample: (samples == 4)
                    .then(|| super::multisample::Multisample::new(&self.device, size)),
                depth_resolve: (samples == 4)
                    .then(|| super::multisample::pipeline(&self.device, reversed_depth)),
                reversed_depth,
                bytes,
                owner,
            };
            let error = pollster::block_on(internal.pop())
                .or(pollster::block_on(memory.pop()))
                .or(pollster::block_on(validation.pop()));
            if let Some(error) = error {
                return Err(error.to_string());
            }
            let state = self.state.as_mut().unwrap();
            state
                .transmission
                .retire_targets(&mut state.draw_cache.borrow_mut());
            state.transmission.targets = Some(candidate);
        }
        self.transmission.targets.as_mut().unwrap().owner = owner;
        self.transmission.materials = materials;
        Ok(())
    }
}

#[cfg(test)]
fn allocation(format: wgpu::TextureFormat, size: [u32; 2], retained: u64) -> Result<u64, String> {
    allocation_at_samples(format, size, 1, retained)
}
fn allocation_at_samples(
    format: wgpu::TextureFormat,
    size: [u32; 2],
    samples: u32,
    retained: u64,
) -> Result<u64, String> {
    if samples != 1 && samples != 4 {
        return Err("Opaque capture supports one or four samples".into());
    }
    let pixels = u64::from(size[0]) * u64::from(size[1]);
    let color = pixels.checked_mul(if format == wgpu::TextureFormat::Rgba16Float {
        8
    } else {
        4
    });
    let bytes = color
        .and_then(|color| {
            pixels
                .checked_mul(4)
                .and_then(|depth| color.checked_add(depth))
        })
        .and_then(|resolved| resolved.checked_mul(if samples == 4 { 5 } else { 1 }));
    if color.is_none_or(|v| v > 64 * 1024 * 1024)
        || bytes
            .and_then(|v| v.checked_add(retained))
            .is_none_or(|v| v > 128 * 1024 * 1024)
    {
        return Err("Transmission capture exceeds its 128 MiB budget or 64 MiB color attachment limit; reduce render size".into());
    }
    Ok(bytes.unwrap())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    #[ignore = "requires a native Metal, Vulkan or DX12 device"]
    fn retired_transmission_textures_are_not_retained_by_any_cached_view() {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let identity = glam::Mat4::IDENTITY.to_cols_array();
        let mut frame: Frame = serde_json::from_value(serde_json::json!({
            "version":1,"view_projection":identity,"background":[0,0,0],
            "light_direction":[0,0,1],"ambient":0.2,
            "geometries":[{"id":1,"positions":[[-0.8,-0.8,0.4],[0.8,-0.8,0.4],[0,0.8,0.4]],"normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
            "meshes":[{"geometry":1,"model":identity,"color":[1,0,0],"unlit":false,"pbr":{"metallic":0,"roughness":1,"emissive":[0.25,0,0]}},
            {"geometry":1,"model":identity,"color":[1,1,1],"unlit":false,"pbr":{"metallic":0,"roughness":0.1,"emissive":[0,0,0],"physical":[1.5,1,0,0,1,1,1,1,0,0,0,0,0,1,1,0],"transmission":[1,0,0,0,1,1,1,0]}}]
        })).unwrap();
        let set_view = |frame: &mut Frame, view| {
            frame.binary = Some(crate::scene_packet::ViewState {
                view,
                revision: 1,
                retained: [1].into_iter().collect(),
                meshes: frame.meshes.clone(),
                retained_textures: Default::default(),
                retained_instances: Default::default(),
                retained_poses: Default::default(),
            });
        };
        let mut last_hash = 0;
        for view in 1..=4 {
            let old = renderer
                .transmission
                .targets
                .as_ref()
                .map(|t| [t.color.texture().clone(), t.depth.texture().clone()]);
            set_view(&mut frame, view);
            let size = 2047 + view as u32;
            last_hash = crc32fast::hash(&renderer.render(&frame, size, size).unwrap());
            frame.geometries.clear();
            assert_eq!(
                renderer.transmission.bytes(),
                u64::from(size) * u64::from(size) * 8
            );
            let mut cache = renderer.draw_cache.borrow_mut();
            if let Some(old) = old {
                for texture in old {
                    assert!(
                        !cache.references_texture(&texture),
                        "retired target is retained by a cached view"
                    );
                }
            }
            let targets = renderer.transmission.targets.as_ref().unwrap();
            assert!(cache.references_texture(targets.color.texture()));
            assert!(cache.references_texture(targets.depth.texture()));
            // Also retain an alias view, so invalidation must match underlying
            // textures rather than just the original texture-view handles.
            cache.texture(targets.color.texture());
            cache.texture(targets.depth.texture());
        }
        let old = {
            let targets = renderer.transmission.targets.as_ref().unwrap();
            [
                targets.color.texture().clone(),
                targets.depth.texture().clone(),
            ]
        };
        let retained_bytes = renderer.transmission.bytes();
        assert!(
            renderer
                .render(&frame, 4096, 4096)
                .unwrap_err()
                .contains("Transmission capture exceeds")
        );
        assert_eq!(renderer.transmission.bytes(), retained_bytes);
        let targets = renderer.transmission.targets.as_ref().unwrap();
        assert_eq!(targets.color.texture(), &old[0]);
        assert_eq!(targets.depth.texture(), &old[1]);
        for texture in &old {
            assert!(renderer.draw_cache.borrow().references_texture(texture));
        }
        assert_eq!(
            crc32fast::hash(&renderer.render(&frame, 2051, 2051).unwrap()),
            last_hash
        );
        assert_eq!(renderer.profile.borrow().draw_preparation_buffers, 0);
        assert_eq!(renderer.profile.borrow().draw_preparation_bind_groups, 0);
        frame.meshes[1].pbr.as_mut().unwrap().transmission[0] = 0.;
        set_view(&mut frame, 5);
        renderer.render(&frame, 31, 31).unwrap();
        assert_eq!(renderer.transmission.bytes(), 0);
        for texture in old {
            assert!(!renderer.draw_cache.borrow().references_texture(&texture));
        }
        frame.meshes[1].pbr.as_mut().unwrap().transmission[0] = 1.;
        for view in [6, 7] {
            set_view(&mut frame, view);
            renderer.render(&frame, 31, 31).unwrap();
        }
        let old = {
            let targets = renderer.transmission.targets.as_ref().unwrap();
            [
                targets.color.texture().clone(),
                targets.depth.texture().clone(),
            ]
        };
        renderer.close_scene_view(7).unwrap();
        assert_eq!(renderer.transmission.bytes(), 0);
        for texture in old {
            assert!(
                !renderer.draw_cache.borrow().references_texture(&texture),
                "closing the active owner left target references in an earlier view"
            );
        }
        for view in 1..=6 {
            renderer.close_scene_view(view).unwrap();
        }
        assert_eq!(renderer.scene_resource_stats().0, 0);
    }
    #[test]
    fn capture_admission_counts_depth_and_resize_overlap() {
        let format = wgpu::TextureFormat::Rgba16Float;
        assert_eq!(
            allocation(format, [1024, 1024], 0).unwrap(),
            12 * 1024 * 1024
        );
        assert_eq!(
            allocation_at_samples(format, [1024, 1024], 4, 0).unwrap(),
            60 * 1024 * 1024
        );
        assert!(allocation_at_samples(format, [1536, 1536], 4, 0).is_err());
        assert!(allocation_at_samples(format, [1024, 1024], 2, 0).is_err());
        let large = allocation(format, [2500, 2500], 0).unwrap();
        assert!(allocation(format, [2600, 2600], large).is_err());
        assert!(allocation(format, [3000, 3000], 0).is_err());
        assert!(allocation(format, [u32::MAX, u32::MAX], 0).is_err());
        assert_eq!(
            allocation(wgpu::TextureFormat::Rgba8UnormSrgb, [1024, 1024], 0).unwrap(),
            8 * 1024 * 1024
        );
    }
}

fn seed(
    device: &wgpu::Device,
    format: wgpu::TextureFormat,
    color: &wgpu::TextureView,
    depth: &wgpu::TextureView,
) -> (wgpu::RenderPipeline, wgpu::BindGroup) {
    let shader = device.create_shader_module(wgpu::include_wgsl!("transmission_seed.wgsl"));
    let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
        label: Some("reuse opaque color and depth"),
        layout: None,
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
            targets: &[Some(wgpu::ColorTargetState {
                format,
                blend: None,
                write_mask: wgpu::ColorWrites::ALL,
            })],
        }),
        primitive: Default::default(),
        depth_stencil: Some(wgpu::DepthStencilState {
            format: wgpu::TextureFormat::Depth32Float,
            depth_write_enabled: Some(true),
            depth_compare: Some(wgpu::CompareFunction::Always),
            stencil: Default::default(),
            bias: Default::default(),
        }),
        multisample: Default::default(),
        multiview_mask: None,
        cache: None,
    });
    let binding = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("opaque seed inputs"),
        layout: &pipeline.get_bind_group_layout(0),
        entries: &[
            wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::TextureView(color),
            },
            wgpu::BindGroupEntry {
                binding: 1,
                resource: wgpu::BindingResource::TextureView(depth),
            },
        ],
    });
    (pipeline, binding)
}

#[cfg(test)]
#[path = "transmission_tests.rs"]
mod native_tests;
