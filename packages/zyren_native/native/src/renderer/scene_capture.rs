use super::Renderer;
use crate::resources::{ResourceError, registry::ResourceKey};

impl Renderer {
    pub(super) fn capture_command(
        &mut self,
        bytes: &[u8],
        capacity: usize,
    ) -> Result<Vec<u8>, ResourceError> {
        use ResourceError::*;
        if self.failure.is_some() {
            return Err(DeviceFailed);
        }
        if bytes.len() < 24 {
            return Err(InvalidCommand);
        }
        let u32_at = |at| u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap());
        let u64_at = |at| u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap());
        if u32_at(0) != 2 || u64_at(16) != (bytes.len() - 24) as u64 {
            return Err(InvalidCommand);
        }
        let opcode = u32_at(4);
        let mut payload = Vec::new();
        match opcode {
            100 => {
                if bytes.len() != 24 || capacity != 32 {
                    return Err(InvalidCommand);
                }
                if self.capture_views.len() >= 4 {
                    return Err(BudgetExceeded);
                }
                self.next_capture_view =
                    self.next_capture_view.checked_add(1).ok_or(DeviceFailed)?;
                let id = self.next_capture_view;
                self.capture_views.insert(id);
                payload.extend(id.to_le_bytes());
            }
            101 => {
                if bytes.len() != 32 || capacity != 24 {
                    return Err(InvalidCommand);
                }
                let id = u64_at(24);
                if !self.capture_views.contains(&id) {
                    return Err(StaleKey);
                }
                self.close_scene_view(id).map_err(|_| DeviceFailed)?;
                self.capture_views.remove(&id);
            }
            102 => {
                if bytes.len() < 72 || capacity != 40 {
                    return Err(InvalidCommand);
                }
                let id = u64_at(24);
                if !self.capture_views.contains(&id) {
                    return Err(StaleKey);
                }
                let key = ResourceKey {
                    renderer: u64_at(32),
                    device_generation: u64_at(40),
                    slot: u64_at(48),
                    slot_generation: u64_at(56),
                };
                if u64_at(64) != (bytes.len() - 72) as u64 {
                    return Err(InvalidCommand);
                }
                let texture = self.resources.graph_texture(key)?;
                if texture.format() != wgpu::TextureFormat::Rgba16Float
                    || texture.dimension() != wgpu::TextureDimension::D2
                    || texture.sample_count() != 1
                    || texture.depth_or_array_layers() != 1
                    || !texture.usage().contains(
                        wgpu::TextureUsages::TEXTURE_BINDING
                            | wgpu::TextureUsages::RENDER_ATTACHMENT,
                    )
                    || texture.width() > 4096
                    || texture.height() > 4096
                {
                    return Err(InvalidUsage);
                }
                let frame = self
                    .decode_scene(&bytes[72..])
                    .map_err(|_| InvalidCommand)?;
                if frame.binary.as_ref().is_none_or(|v| v.view != id)
                    || frame.color_pipeline.is_some()
                    || frame.temporal.is_some()
                    || frame.settings.enabled
                    || frame.sample_count() != 1
                {
                    return Err(InvalidUsage);
                }
                // A caller may supply a linear HDR graph, but display transforms
                // cannot be inferred or removed from arbitrary shader programs.
                if let Some(graph) = self
                    .resolve_frame_graph(&frame, texture.width(), texture.height())
                    .map_err(|_| InvalidUsage)?
                {
                    if graph.output.format() != wgpu::TextureFormat::Rgba16Float {
                        return Err(InvalidUsage);
                    }
                }
                {
                    let state = self.state.as_mut().unwrap();
                    state.resources.prepare_queued_scene(&state.device)?;
                }
                let size = [texture.width(), texture.height()];
                // Main-frame query buffers are mapped after submission. Auxiliary
                // jobs never reuse those buffers or report unmeasured GPU time.
                let timer = self.gpu_timer.take();
                let old_profile = std::mem::take(&mut *self.profile.borrow_mut());
                let old_time = self.last_gpu_time_ns;
                let old_source = self.gpu_time_source;
                let result =
                    self.render_to_target(&frame, texture, None, size[0], size[1], Some(key));
                self.gpu_timer = timer;
                *self.profile.borrow_mut() = old_profile;
                self.last_gpu_time_ns = old_time;
                self.gpu_time_source = old_source;
                result.map_err(|_| {
                    if self.failure.is_some() {
                        DeviceFailed
                    } else {
                        InvalidUsage
                    }
                })?;
                payload.extend(self.last_scene_draws.get().to_le_bytes());
                let attachments = u64::from(size[0])
                    * u64::from(size[1])
                    * (4 + if frame.background_alpha < 1. { 8 } else { 0 })
                    + self.transmission.bytes();
                payload.extend(attachments.to_le_bytes());
            }
            _ => return Err(InvalidCommand),
        }
        let mut response = Vec::with_capacity(24 + payload.len());
        response.extend(2_u32.to_le_bytes());
        response.extend(0_u32.to_le_bytes());
        response.extend(u64_at(8).to_le_bytes());
        response.extend((payload.len() as u64).to_le_bytes());
        response.extend(payload);
        Ok(response)
    }
}
