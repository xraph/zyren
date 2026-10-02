use std::sync::mpsc::{self, Receiver};

const FEATURES: wgpu::Features =
    wgpu::Features::TIMESTAMP_QUERY.union(wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS);

pub(super) fn features(available: wgpu::Features, backend: wgpu::Backend) -> wgpu::Features {
    if backend != wgpu::Backend::Metal && available.contains(FEATURES) {
        FEATURES
    } else {
        wgpu::Features::empty()
    }
}

// One submission is in flight per renderer. Reuse two queries and 32 buffer
// bytes across all views; the pending read is consumed before another submit.
pub(super) struct Timer {
    queries: wgpu::QuerySet,
    resolve: wgpu::Buffer,
    readback: wgpu::Buffer,
    period: f32,
}
pub(super) struct Pending {
    readback: wgpu::Buffer,
    receiver: Receiver<Result<(), wgpu::BufferAsyncError>>,
    period: f32,
}
impl Timer {
    pub(super) fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Option<Self> {
        if !device.features().contains(FEATURES) {
            return None;
        }
        let buffer = |label, usage| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: 16,
                usage,
                mapped_at_creation: false,
            })
        };
        Some(Self {
            queries: device.create_query_set(&wgpu::QuerySetDescriptor {
                label: Some("frame GPU duration"),
                ty: wgpu::QueryType::Timestamp,
                count: 2,
            }),
            resolve: buffer(
                "timestamp resolve",
                wgpu::BufferUsages::QUERY_RESOLVE | wgpu::BufferUsages::COPY_SRC,
            ),
            readback: buffer(
                "timestamp readback",
                wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            ),
            period: queue.get_timestamp_period(),
        })
    }
    pub(super) fn begin(&self, encoder: &mut wgpu::CommandEncoder) {
        encoder.write_timestamp(&self.queries, 0);
    }
    pub(super) fn end(&self, encoder: &mut wgpu::CommandEncoder) -> Pending {
        encoder.write_timestamp(&self.queries, 1);
        encoder.resolve_query_set(&self.queries, 0..2, &self.resolve, 0);
        encoder.copy_buffer_to_buffer(&self.resolve, 0, &self.readback, 0, 16);
        let (sender, receiver) = mpsc::sync_channel(1);
        encoder.map_buffer_on_submit(&self.readback, wgpu::MapMode::Read, .., move |result| {
            let _ = sender.send(result);
        });
        Pending {
            readback: self.readback.clone(),
            receiver,
            period: self.period,
        }
    }
}
impl Pending {
    // Polling the submission already delivered its mapping callback. Telemetry
    // never introduces a second blocking GPU wait or fabricates a CPU duration.
    pub(super) fn nanoseconds(self) -> Option<u64> {
        self.receiver.try_recv().ok()?.ok()?;
        let mapped = self.readback.get_mapped_range(..).ok()?;
        let start = u64::from_le_bytes(mapped[0..8].try_into().ok()?);
        let end = u64::from_le_bytes(mapped[8..16].try_into().ok()?);
        duration(start, end, self.period)
    }
}
impl Drop for Pending {
    fn drop(&mut self) {
        self.readback.unmap();
    }
}
fn duration(start: u64, end: u64, period: f32) -> Option<u64> {
    let ns = end.checked_sub(start)? as f64 * f64::from(period);
    (period.is_finite() && period > 0. && ns < u64::MAX as f64).then_some(ns as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn timestamp_admission_requires_both_features_and_keeps_metal_completion() {
        for available in [
            wgpu::Features::empty(),
            wgpu::Features::TIMESTAMP_QUERY,
            wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS,
            FEATURES,
        ] {
            for backend in [
                wgpu::Backend::Metal,
                wgpu::Backend::Vulkan,
                wgpu::Backend::Dx12,
            ] {
                assert_eq!(
                    features(available, backend),
                    if available == FEATURES && backend != wgpu::Backend::Metal {
                        FEATURES
                    } else {
                        wgpu::Features::empty()
                    }
                );
            }
        }
    }
    #[test]
    fn timestamp_duration_rejects_wraparound_invalid_periods_and_overflow() {
        assert_eq!(duration(100, 110, 2.5), Some(25));
        assert_eq!(duration(100, 100, 1.), Some(0));
        assert_eq!(duration(u64::MAX, 1, 1.), None);
        assert_eq!(duration(0, u64::MAX, 2.), None);
        for period in [0., -1., f32::NAN, f32::INFINITY] {
            assert_eq!(duration(1, 2, period), None);
        }
    }
}
