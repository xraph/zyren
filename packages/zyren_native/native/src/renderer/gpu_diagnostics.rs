use std::time::Duration;

/// Two GPU timestamps. Allocate only after the first inspection request.
/// Read back only on demand, and retain no sample history.
pub(crate) struct GpuTimer {
    queries: wgpu::QuerySet,
    resolved: wgpu::Buffer,
    sample_ready: bool,
    pub(crate) readback_bytes: u64,
}
impl GpuTimer {
    pub(crate) fn new(device: &wgpu::Device) -> Self {
        Self {
            queries: device.create_query_set(&wgpu::QuerySetDescriptor {
                label: Some("diagnostic scene timestamps"),
                ty: wgpu::QueryType::Timestamp,
                count: 2,
            }),
            resolved: device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("diagnostic timestamp resolve"),
                size: 16,
                usage: wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
                mapped_at_creation: false,
            }),
            sample_ready: false,
            readback_bytes: 0,
        }
    }
    pub(crate) fn begin(&self, encoder: &mut wgpu::CommandEncoder) {
        encoder.write_timestamp(&self.queries, 0);
    }
    pub(crate) fn end(&mut self, encoder: &mut wgpu::CommandEncoder) {
        self.sample_ready = false;
        encoder.write_timestamp(&self.queries, 1);
        encoder.resolve_query_set(&self.queries, 0..2, &self.resolved, 0);
    }
    pub(crate) fn completed(&mut self) {
        self.sample_ready = true;
    }
    pub(crate) fn sample(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
    ) -> Result<Option<u64>, String> {
        if !self.sample_ready {
            return Ok(None);
        }
        let staging = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("diagnostic timestamp readback"),
            size: 16,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });
        let mut encoder = device.create_command_encoder(&Default::default());
        encoder.copy_buffer_to_buffer(&self.resolved, 0, &staging, 0, 16);
        let submission = queue.submit([encoder.finish()]);
        let (tx, rx) = std::sync::mpsc::channel();
        staging
            .slice(..)
            .map_async(wgpu::MapMode::Read, move |result| {
                let _ = tx.send(result);
            });
        device
            .poll(wgpu::PollType::Wait {
                submission_index: Some(submission),
                timeout: Some(Duration::from_secs(2)),
            })
            .map_err(|error| error.to_string())?;
        rx.recv_timeout(Duration::from_secs(2))
            .map_err(|error| error.to_string())?
            .map_err(|error| error.to_string())?;
        let data = staging
            .slice(..)
            .get_mapped_range()
            .map_err(|error| error.to_string())?;
        let start = u64::from_le_bytes(data[..8].try_into().unwrap());
        let end = u64::from_le_bytes(data[8..].try_into().unwrap());
        drop(data);
        staging.unmap();
        self.readback_bytes = self.readback_bytes.saturating_add(16);
        Ok(timestamp_duration(start, end, queue.get_timestamp_period()))
    }
}
fn timestamp_duration(start: u64, end: u64, period: f32) -> Option<u64> {
    // wgpu does not expose timestampValidBits; reject wrapped counters.
    let delta = end.checked_sub(start)?;
    let nanos = delta as f64 * period as f64;
    (period.is_finite() && period > 0.0 && nanos.is_finite() && nanos < u64::MAX as f64)
        .then_some(nanos as u64)
}
#[cfg(test)]
mod tests {
    use super::timestamp_duration;
    #[test]
    fn duration_rejects_wrapped_and_invalid_device_timestamps() {
        assert_eq!(timestamp_duration(10, 20, 2.5), Some(25));
        assert_eq!(timestamp_duration(u64::MAX, 2, 1.0), None);
        assert_eq!(timestamp_duration(0, u64::MAX, f32::MAX), None);
        for period in [0.0, -1.0, f32::NAN, f32::INFINITY] {
            assert_eq!(timestamp_duration(1, 2, period), None);
        }
    }
}
