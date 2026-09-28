use super::*;
use std::ops::Range;

pub(super) const STRIDE: u64 = 112;
const BUDGET: u64 = 64 * 1024 * 1024;
pub(super) const ATTRIBUTES: [wgpu::VertexAttribute; 7] = wgpu::vertex_attr_array![
    5=>Float32x4,6=>Float32x4,7=>Float32x4,8=>Float32x4,
    9=>Float32x4,10=>Float32x4,11=>Float32x4];
pub(super) fn layout() -> wgpu::VertexBufferLayout<'static> {
    wgpu::VertexBufferLayout {
        array_stride: STRIDE,
        step_mode: wgpu::VertexStepMode::Instance,
        attributes: &ATTRIBUTES,
    }
}
pub(super) struct Draw {
    pub mesh: usize,
    pub range: Range<u32>,
    pub mirrored: bool,
    pub instanced: bool,
}
pub(super) struct View {
    pub buffer: Option<wgpu::Buffer>,
    pub draws: Vec<Draw>,
    values: Vec<[f32; 28]>,
}
#[derive(Default)]
pub(super) struct Instances {
    views: HashMap<u64, View>,
    pub uploaded_bytes: u64,
}
pub(super) fn view_id(frame: &Frame) -> u64 {
    frame.binary.as_ref().map_or(0, |b| b.view)
}
impl Instances {
    pub fn bytes(&self) -> u64 {
        self.views
            .values()
            .map(|v| v.values.len() as u64 * STRIDE)
            .sum()
    }
    pub fn draws(&self) -> usize {
        self.views
            .values()
            .flat_map(|v| &v.draws)
            .filter(|d| d.instanced)
            .count()
    }
    pub fn remove(&mut self, id: u64) {
        self.views.remove(&id);
    }
    pub fn view(&self, frame: &Frame) -> &View {
        &self.views[&view_id(frame)]
    }
    pub fn admit(&self, frame: &Frame) -> Result<(), String> {
        let required = frame
            .meshes
            .iter()
            .map(|m| m.instances.len() as u64 * STRIDE)
            .sum::<u64>();
        let previous = self
            .views
            .get(&view_id(frame))
            .map_or(0, |v| v.values.len() as u64 * STRIDE);
        if self.bytes() - previous + required > BUDGET {
            return Err("Instance buffer budget exceeded".into());
        }
        Ok(())
    }
    pub fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        frame: &Frame,
        geometries: &HashMap<u32, GpuGeometry>,
    ) -> Result<(), String> {
        self.admit(frame)?;
        let vp = Mat4::from_cols_array(&frame.view_projection);
        let mut order = Vec::new();
        for (index, mesh) in frame.meshes.iter().enumerate() {
            let models = if mesh.instances.is_empty() {
                std::slice::from_ref(&mesh.model)
            } else {
                &mesh.instances
            };
            for (slot, values) in models.iter().enumerate() {
                let model = Mat4::from_cols_array(values);
                let clip = vp * model * geometries[&mesh.geometry].center.extend(1.);
                let depth = if clip.w.abs() > 1e-20 {
                    clip.z / clip.w
                } else {
                    clip.z
                };
                order.push((index, slot, model.determinant() < 0., depth));
            }
        }
        order.sort_by(|a, b| {
            let left = &frame.meshes[a.0];
            let right = &frame.meshes[b.0];
            let blend = left.alpha_mode == 2;
            blend
                .cmp(&(right.alpha_mode == 2))
                .then(left.render_order.cmp(&right.render_order))
                .then_with(|| {
                    if blend {
                        b.3.total_cmp(&a.3)
                    } else {
                        std::cmp::Ordering::Equal
                    }
                })
                .then(a.0.cmp(&b.0))
                .then_with(|| {
                    if blend {
                        std::cmp::Ordering::Equal
                    } else {
                        a.2.cmp(&b.2)
                    }
                })
                .then(a.1.cmp(&b.1))
        });
        let mut values = Vec::new();
        let mut draws: Vec<Draw> = Vec::new();
        for (index, slot, mirrored, _) in order {
            let mesh = &frame.meshes[index];
            let instanced = !mesh.instances.is_empty();
            let first = values.len() as u32;
            if instanced {
                let model = Mat4::from_cols_array(&mesh.instances[slot]);
                let normal = model.inverse().transpose();
                let mut value = [0.; 28];
                value[..16].copy_from_slice(&mesh.instances[slot]);
                value[16..20].copy_from_slice(&normal.x_axis.to_array());
                value[20..24].copy_from_slice(&normal.y_axis.to_array());
                value[24..28].copy_from_slice(&normal.z_axis.to_array());
                values.push(value);
            }
            if instanced
                && let Some(last) = draws.last_mut()
                && last.instanced
                && last.mesh == index
                && last.mirrored == mirrored
            {
                last.range.end += 1;
            } else {
                draws.push(Draw {
                    mesh: index,
                    range: if instanced { first..first + 1 } else { 0..1 },
                    mirrored,
                    instanced,
                });
            }
        }
        let id = view_id(frame);
        let buffer = if values.is_empty() {
            None
        } else if let Some(old) = self
            .views
            .get(&id)
            .filter(|v| v.values.len() == values.len())
        {
            let buffer = old.buffer.as_ref().expect("nonempty instance buffer");
            let mut start = 0;
            while start < values.len() {
                if values[start] == old.values[start] {
                    start += 1;
                    continue;
                }
                let mut end = start + 1;
                while end < values.len() && values[end] != old.values[end] {
                    end += 1;
                }
                queue.write_buffer(
                    buffer,
                    start as u64 * STRIDE,
                    bytemuck::cast_slice(&values[start..end]),
                );
                self.uploaded_bytes += (end - start) as u64 * STRIDE;
                start = end;
            }
            Some(buffer.clone())
        } else {
            let validation = device.push_error_scope(wgpu::ErrorFilter::Validation);
            let memory = device.push_error_scope(wgpu::ErrorFilter::OutOfMemory);
            let buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("view instances"),
                contents: bytemuck::cast_slice(&values),
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            });
            let mut failure = None;
            for scope in [memory, validation] {
                if let Some(error) = pollster::block_on(scope.pop()) {
                    failure = Some(error.to_string());
                }
            }
            if let Some(error) = failure {
                return Err(error);
            }
            self.uploaded_bytes += values.len() as u64 * STRIDE;
            Some(buffer)
        };
        self.views.insert(
            id,
            View {
                buffer,
                draws,
                values,
            },
        );
        Ok(())
    }
}
