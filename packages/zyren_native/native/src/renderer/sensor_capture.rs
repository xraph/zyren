use super::*;

impl Renderer {
    pub(super) fn prepare_sensor_depth(&mut self) {
        let state = self.state.as_mut().expect("live renderer");
        let target = state.targets.as_mut().expect("prepared target");
        if target.sensor_depth.is_none() {
            target.sensor_depth = Some(state.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("sensor depth readback"),
                size: target.stride as u64 * target.height as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            }));
        }
    }

    pub(super) fn encode_sensor_depth(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        frame: &Frame,
    ) -> wgpu::Buffer {
        let target = self.targets.as_ref().expect("prepared target");
        let buffer = target.sensor_depth.as_ref().expect("prepared depth");
        let source = if frame.settings.enabled {
            self.effects
                .sensor_depth(frame)
                .expect("prepared effect depth")
        } else {
            &target._depth
        };
        encoder.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: source,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::DepthOnly,
            },
            wgpu::TexelCopyBufferInfo {
                buffer,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(target.stride),
                    rows_per_image: Some(target.height),
                },
            },
            wgpu::Extent3d {
                width: target.width,
                height: target.height,
                depth_or_array_layers: 1,
            },
        );
        buffer.clone()
    }

    pub(super) fn read_sensor_depth(
        &mut self,
        buffer: &wgpu::Buffer,
        width: u32,
        stride: u32,
        len: usize,
    ) -> Result<Vec<u8>, String> {
        let (sender, receiver) = mpsc::sync_channel(1);
        buffer
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = sender.send(result);
            });
        self.device
            .poll(wgpu::PollType::Wait {
                submission_index: None,
                timeout: Some(Duration::from_secs(2)),
            })
            .map_err(|error| format!("sensor depth poll failed: {error}"))?;
        let mapped = receiver
            .recv_timeout(Duration::from_secs(1))
            .map_err(|error| format!("sensor depth callback failed: {error}"))
            .and_then(|result| result.map_err(|error| format!("sensor depth map failed: {error}")));
        self.copy_readback(buffer, width, stride, len, mapped)
    }
}
