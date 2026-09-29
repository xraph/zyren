use super::Renderer;
use crate::{
    render_graph::{FrameGraph, PreparedMaterial},
    scene::Frame,
};

pub(super) struct Targets {
    pub color: wgpu::TextureView,
    pub depth: wgpu::TextureView,
    size: [u32; 2],
    format: wgpu::TextureFormat,
    bytes: u64,
    owner: u64,
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
            materials: Vec::new(),
            defaults: [
                texture(device, wgpu::TextureFormat::Rgba8Unorm, [1, 1]),
                texture(device, wgpu::TextureFormat::Depth32Float, [1, 1]),
            ],
        }
    }
    pub fn remove(&mut self, view: u64) {
        if self.targets.as_ref().is_some_and(|t| t.owner == view) {
            self.targets = None;
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
            .any(|m| m.color_visible && m.transmissive())
        {
            self.transmission.targets = None;
            self.transmission.materials.clear();
            return Ok(());
        }
        let owner = frame.binary.as_ref().map_or(0, |b| b.view);
        let reuse = self
            .transmission
            .targets
            .as_ref()
            .is_some_and(|t| t.size == size && t.format == format);
        let bytes = allocation(
            format,
            size,
            if reuse { 0 } else { self.transmission.bytes() },
        )?;
        let materials = self.prepare_materials_at_samples(frame, format, graph, 1)?;
        if !reuse {
            let validation = self.device.push_error_scope(wgpu::ErrorFilter::Validation);
            let memory = self.device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
            let internal = self.device.push_error_scope(wgpu::ErrorFilter::Internal);
            let candidate = Targets {
                color: texture(&self.device, format, size),
                depth: texture(&self.device, wgpu::TextureFormat::Depth32Float, size),
                size,
                format,
                bytes,
                owner,
            };
            let error = pollster::block_on(internal.pop())
                .or(pollster::block_on(memory.pop()))
                .or(pollster::block_on(validation.pop()));
            if let Some(error) = error {
                return Err(error.to_string());
            }
            self.transmission.targets = Some(candidate);
        }
        self.transmission.targets.as_mut().unwrap().owner = owner;
        self.transmission.materials = materials;
        Ok(())
    }
}

fn allocation(format: wgpu::TextureFormat, size: [u32; 2], retained: u64) -> Result<u64, String> {
    let pixels = u64::from(size[0]) * u64::from(size[1]);
    let color = pixels.checked_mul(if format == wgpu::TextureFormat::Rgba16Float {
        8
    } else {
        4
    });
    let bytes = color.and_then(|color| {
        pixels
            .checked_mul(4)
            .and_then(|depth| color.checked_add(depth))
    });
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
    fn capture_admission_counts_depth_and_resize_overlap() {
        let format = wgpu::TextureFormat::Rgba16Float;
        assert_eq!(
            allocation(format, [1024, 1024], 0).unwrap(),
            12 * 1024 * 1024
        );
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
