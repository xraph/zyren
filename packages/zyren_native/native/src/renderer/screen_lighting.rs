//! Current-view opaque inputs. No history survives a submission.
use super::{Renderer, draw_cache};
use crate::{
    render_graph::{FrameGraph, PreparedMaterial},
    scene::Frame,
};
use bytemuck::{Pod, Zeroable};

#[derive(Clone, PartialEq, serde::Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Settings {
    pub ao: bool,
    pub reflections: bool,
    pub quality: u32,
    pub radius: f32,
    pub intensity: f32,
    pub bias: f32,
    pub max_distance: f32,
    pub thickness: f32,
    pub max_roughness: f32,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            ao: false,
            reflections: false,
            quality: 1,
            radius: 0.5,
            intensity: 1.,
            bias: 0.02,
            max_distance: 20.,
            thickness: 0.2,
            max_roughness: 0.6,
        }
    }
}
impl Settings {
    pub fn enabled(&self) -> bool {
        self.ao || self.reflections
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.quality > 2
            || [
                (self.radius, 1000.),
                (self.max_distance, 10000.),
                (self.thickness, 100.),
                (self.max_roughness, 1.),
            ]
            .iter()
            .any(|(v, m)| !v.is_finite() || *v <= 0. || v > m)
            || [self.intensity, self.bias]
                .iter()
                .any(|v| !v.is_finite() || !(0.0..=1.).contains(v))
        {
            return Err("Invalid screen-space lighting parameters".into());
        }
        Ok(())
    }
    fn uniforms(&self) -> Uniforms {
        Uniforms {
            ao: [
                self.radius,
                self.intensity,
                self.bias,
                if self.ao {
                    [8., 12., 16.][self.quality as usize]
                } else {
                    0.
                },
            ],
            reflection: [
                self.max_distance,
                self.thickness,
                self.max_roughness,
                if self.reflections {
                    [16., 32., 64.][self.quality as usize]
                } else {
                    0.
                },
            ],
        }
    }
}
#[repr(C)]
#[derive(Clone, Copy, Pod, Zeroable)]
pub(super) struct Uniforms {
    ao: [f32; 4],
    reflection: [f32; 4],
}
pub(super) const UNIFORM_BYTES: usize = std::mem::size_of::<Uniforms>();
pub(super) const FORMAT: wgpu::TextureFormat = wgpu::TextureFormat::Rgba16Float;
const MAX_BYTES: u64 = 128 * 1024 * 1024;
pub(super) struct Targets {
    pub color: wgpu::TextureView,
    pub depth: wgpu::TextureView,
    size: [u32; 2],
    owner: u64,
    bytes: u64,
}
pub(super) struct System {
    pub targets: Option<Targets>,
    pub materials: Vec<Option<PreparedMaterial>>,
    defaults: [wgpu::TextureView; 2],
}
fn texture(
    device: &wgpu::Device,
    format: wgpu::TextureFormat,
    size: [u32; 2],
) -> wgpu::TextureView {
    device
        .create_texture(&wgpu::TextureDescriptor {
            label: Some("screen lighting opaque source"),
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
            materials: Vec::new(),
            defaults: [
                texture(device, FORMAT, [1, 1]),
                texture(device, wgpu::TextureFormat::Depth32Float, [1, 1]),
            ],
        }
    }
    pub fn bytes(&self) -> u64 {
        self.targets.as_ref().map_or(0, |t| t.bytes)
    }
    fn retire(
        &mut self,
        device: &wgpu::Device,
        cache: &mut draw_cache::Cache,
    ) -> Result<(), String> {
        if self.targets.is_some() {
            device
                .poll(wgpu::PollType::Wait {
                    submission_index: None,
                    timeout: Some(std::time::Duration::from_secs(5)),
                })
                .map_err(|e| format!("Screen lighting retirement: {e}"))?;
        }
        if let Some(t) = self.targets.take() {
            cache.invalidate_textures(&[t.color.texture(), t.depth.texture()]);
        }
        self.materials.clear();
        Ok(())
    }
    pub fn remove(
        &mut self,
        view: u64,
        device: &wgpu::Device,
        cache: &mut draw_cache::Cache,
    ) -> Result<(), String> {
        if self.targets.as_ref().is_some_and(|t| t.owner == view) {
            self.retire(device, cache)?;
        }
        Ok(())
    }
    pub fn entries<'a>(
        &'a self,
        source: bool,
        buffer: &'a wgpu::Buffer,
    ) -> [wgpu::BindGroupEntry<'a>; 3] {
        let views = self
            .targets
            .as_ref()
            .filter(|_| !source)
            .map_or([&self.defaults[0], &self.defaults[1]], |t| {
                [&t.color, &t.depth]
            });
        [
            wgpu::BindGroupEntry {
                binding: 16,
                resource: buffer.as_entire_binding(),
            },
            wgpu::BindGroupEntry {
                binding: 17,
                resource: wgpu::BindingResource::TextureView(views[0]),
            },
            wgpu::BindGroupEntry {
                binding: 18,
                resource: wgpu::BindingResource::TextureView(views[1]),
            },
        ]
    }
}
pub(super) fn layout_entries() -> Vec<wgpu::BindGroupLayoutEntry> {
    let mut entries = vec![wgpu::BindGroupLayoutEntry {
        binding: 16,
        visibility: wgpu::ShaderStages::FRAGMENT,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: wgpu::BufferSize::new(UNIFORM_BYTES as u64),
        },
        count: None,
    }];
    for (binding, sample_type) in [
        (17, wgpu::TextureSampleType::Float { filterable: false }),
        (18, wgpu::TextureSampleType::Depth),
    ] {
        entries.push(wgpu::BindGroupLayoutEntry {
            binding,
            visibility: wgpu::ShaderStages::FRAGMENT,
            ty: wgpu::BindingType::Texture {
                sample_type,
                view_dimension: wgpu::TextureViewDimension::D2,
                multisampled: false,
            },
            count: None,
        });
    }
    entries
}
fn allocation(size: [u32; 2], retained: u64) -> Result<u64, String> {
    let bytes = u64::from(size[0])
        .checked_mul(u64::from(size[1]))
        .and_then(|v| v.checked_mul(12));
    if bytes
        .and_then(|v| v.checked_add(retained))
        .and_then(|v| v.checked_add(12))
        .is_none_or(|v| v > MAX_BYTES)
    {
        return Err("Screen-space lighting exceeds its 128 MiB attachment budget including replacement overlap; reduce render size".into());
    }
    Ok(bytes.unwrap())
}
impl Renderer {
    pub(super) fn screen_lighting_uniform(&self, frame: &Frame, source: bool) -> wgpu::Buffer {
        let settings = frame.settings.screen_lighting.as_ref().filter(|_| !source);
        self.draw_uniform(
            draw_cache::UniformKey::ScreenLighting(source),
            bytemuck::bytes_of(&settings.map_or(Uniforms::zeroed(), Settings::uniforms)),
        )
    }
    pub(super) fn prepare_screen_lighting(
        &mut self,
        frame: &Frame,
        size: [u32; 2],
        graph: Option<&FrameGraph>,
    ) -> Result<(), String> {
        if !frame
            .settings
            .screen_lighting
            .as_ref()
            .is_some_and(Settings::enabled)
        {
            let state = self.state.as_mut().unwrap();
            state.screen_lighting.remove(
                frame.binary.as_ref().map_or(0, |b| b.view),
                &state.device,
                &mut state.draw_cache.borrow_mut(),
            )?;
            return Ok(());
        }
        let reuse = self
            .screen_lighting
            .targets
            .as_ref()
            .is_some_and(|t| t.size == size);
        let bytes = allocation(
            size,
            if reuse {
                0
            } else {
                self.screen_lighting.bytes()
            },
        )?;
        let materials = self.prepare_materials_in_format(frame, FORMAT, graph, 1, false)?;
        let owner = frame.binary.as_ref().map_or(0, |b| b.view);
        if !reuse {
            let validation = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
            let memory = self.device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
            let internal = self.device.push_error_scope(wgpu::ErrorFilter::Internal);
            let target = Targets {
                color: texture(&self.device, FORMAT, size),
                depth: texture(&self.device, wgpu::TextureFormat::Depth32Float, size),
                size,
                owner,
                bytes,
            };
            let error = pollster::block_on(internal.pop())
                .or(pollster::block_on(memory.pop()))
                .or(pollster::block_on(validation.pop()));
            if let Some(e) = error {
                return Err(e.to_string());
            }
            let state = self.state.as_mut().unwrap();
            state
                .screen_lighting
                .retire(&state.device, &mut state.draw_cache.borrow_mut())?;
            state.screen_lighting.targets = Some(target);
        }
        self.screen_lighting.targets.as_mut().unwrap().owner = owner;
        self.screen_lighting.materials = materials;
        Ok(())
    }
}

#[cfg(test)]
#[path = "screen_lighting_tests.rs"]
mod tests;
