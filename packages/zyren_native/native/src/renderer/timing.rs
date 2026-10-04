use std::{
    cell::Cell,
    sync::mpsc::{self, Receiver},
};

const FEATURES: wgpu::Features =
    wgpu::Features::TIMESTAMP_QUERY.union(wgpu::Features::TIMESTAMP_QUERY_INSIDE_ENCODERS);
pub(super) fn features(available: wgpu::Features, backend: wgpu::Backend) -> wgpu::Features {
    if backend != wgpu::Backend::Metal && available.contains(FEATURES) {
        FEATURES
    } else {
        wgpu::Features::empty()
    }
}

#[derive(Clone, Copy)]
#[repr(usize)]
pub(super) enum Pass {
    EnergyLut,
    ResourceGraphBefore,
    Shadows,
    Transmission,
    Scene,
    OutlineMask,
    AlphaResolve,
    Temporal,
    ResourceGraphAfter,
    Output,
    Outlines,
    Effects,
    ResizeComposite,
}
pub(super) const PASSES: [&str; 13] = [
    "energyLut",
    "resourceGraphBefore",
    "shadows",
    "transmission",
    "scene",
    "outlineMask",
    "alphaResolve",
    "temporal",
    "resourceGraphAfter",
    "output",
    "outlines",
    "effects",
    "resizeComposite",
];
const SLOTS: usize = PASSES.len() + 1;
pub(super) const BUFFER_BYTES: u64 = (SLOTS * 16) as u64;

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Profile {
    pub status: &'static str,
    pub cpu_prepare_ns: Option<u64>,
    pub cpu_encode_ns: Option<u64>,
    pub cpu_completion_wait_ns: Option<u64>,
    pub cpu_readback_ns: Option<u64>,
    pub gpu_time_ns: Option<u64>,
    pub gpu_time_source: &'static str,
    pub submission_count: u64,
    pub draw_preparation_buffers: u64,
    pub draw_preparation_bind_groups: u64,
    pub draw_cache_reuses: Option<u64>,
    pub draw_uniform_reuses: Option<u64>,
    pub draw_uniform_write_calls: Option<u64>,
    pub draw_uniform_write_bytes: Option<u64>,
    pub draw_uniform_skipped_writes: Option<u64>,
    pub draw_cache_entries: Option<u64>,
    pub draw_cache_uniform_bytes: Option<u64>,
    pub draw_plan_reuses: Option<u64>,
    pub executed_mesh_draws: Option<u64>,
    pub opaque_batch_draws: Option<u64>,
    pub batched_source_draws: Option<u64>,
    pub pipeline_switches: Option<u64>,
    pub bind_group_switches: Option<u64>,
    pub automatic_instance_upload_bytes: Option<u64>,
    pub upload_bytes: u64,
    pub upload_backlog_bytes: u64,
    pub staged_bytes: u64,
    pub candidate_ready: bool,
    pub passes: std::collections::BTreeMap<&'static str, PassSample>,
}
#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct PassSample {
    pub draw_calls: Option<u64>,
    pub executed: bool,
    pub gpu_time_ns: Option<u64>,
}
impl Default for Profile {
    fn default() -> Self {
        Self {
            status: "unavailable",
            cpu_prepare_ns: None,
            cpu_encode_ns: None,
            cpu_completion_wait_ns: None,
            cpu_readback_ns: None,
            gpu_time_ns: None,
            gpu_time_source: "unavailable",
            submission_count: 0,
            draw_preparation_buffers: 0,
            draw_preparation_bind_groups: 0,
            draw_cache_reuses: None,
            draw_uniform_reuses: None,
            draw_uniform_write_calls: None,
            draw_uniform_write_bytes: None,
            draw_uniform_skipped_writes: None,
            draw_cache_entries: None,
            draw_cache_uniform_bytes: None,
            draw_plan_reuses: None,
            executed_mesh_draws: None,
            opaque_batch_draws: None,
            batched_source_draws: None,
            pipeline_switches: None,
            bind_group_switches: None,
            automatic_instance_upload_bytes: None,
            upload_bytes: 0,
            upload_backlog_bytes: 0,
            staged_bytes: 0,
            candidate_ready: true,
            passes: PASSES
                .into_iter()
                .map(|name| {
                    (
                        name,
                        PassSample {
                            draw_calls: None,
                            executed: false,
                            gpu_time_ns: None,
                        },
                    )
                })
                .collect(),
        }
    }
}

// One scene submission is in flight. Fixed query slots and two buffers are
// reused after completion; absent passes are never resolved or read as zero.
pub(super) struct Timer {
    queries: wgpu::QuerySet,
    resolve: wgpu::Buffer,
    readback: wgpu::Buffer,
    period: f32,
    written: Cell<u32>,
}
pub(super) struct Pending {
    readback: wgpu::Buffer,
    receiver: Receiver<Result<(), wgpu::BufferAsyncError>>,
    period: f32,
    written: u32,
}
impl Timer {
    pub(super) fn new(device: &wgpu::Device, queue: &wgpu::Queue) -> Option<Self> {
        if !device.features().contains(FEATURES) {
            return None;
        }
        let buffer = |label, usage| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: Some(label),
                size: BUFFER_BYTES,
                usage,
                mapped_at_creation: false,
            })
        };
        Some(Self {
            queries: device.create_query_set(&wgpu::QuerySetDescriptor {
                label: Some("frame and named GPU durations"),
                ty: wgpu::QueryType::Timestamp,
                count: (SLOTS * 2) as u32,
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
            written: Cell::new(0),
        })
    }
    pub(super) fn begin(&self, encoder: &mut wgpu::CommandEncoder) {
        self.written.set(1);
        encoder.write_timestamp(&self.queries, 0);
    }
    pub(super) fn begin_pass(&self, encoder: &mut wgpu::CommandEncoder, pass: Pass) {
        let slot = pass as u32 + 1;
        self.written.set(self.written.get() | (1 << slot));
        encoder.write_timestamp(&self.queries, slot * 2);
    }
    pub(super) fn end_pass(&self, encoder: &mut wgpu::CommandEncoder, pass: Pass) {
        encoder.write_timestamp(&self.queries, (pass as u32 + 1) * 2 + 1);
    }
    pub(super) fn end(&self, encoder: &mut wgpu::CommandEncoder) -> Pending {
        encoder.write_timestamp(&self.queries, 1);
        let written = self.written.get();
        // Resolve offsets require 256-byte alignment. Resolve each pair at zero
        // and copy it to its slot before the next resolve overwrites that pair.
        for slot in 0..SLOTS as u32 {
            if written & (1 << slot) != 0 {
                encoder.resolve_query_set(&self.queries, slot * 2..slot * 2 + 2, &self.resolve, 0);
                encoder.copy_buffer_to_buffer(
                    &self.resolve,
                    0,
                    &self.readback,
                    u64::from(slot) * 16,
                    16,
                );
            }
        }
        let (sender, receiver) = mpsc::sync_channel(1);
        encoder.map_buffer_on_submit(&self.readback, wgpu::MapMode::Read, .., move |result| {
            let _ = sender.send(result);
        });
        Pending {
            readback: self.readback.clone(),
            receiver,
            period: self.period,
            written,
        }
    }
}
impl Pending {
    pub(super) fn copied_bytes(&self) -> u64 {
        u64::from(self.written.count_ones()) * 16
    }
    pub(super) fn read(self, profile: &mut Profile) -> Option<u64> {
        self.receiver.try_recv().ok()?.ok()?;
        let mapped = self.readback.get_mapped_range(..).ok()?;
        let sample = |slot| sample(&mapped, self.written, slot, self.period);
        for (i, name) in PASSES.iter().enumerate() {
            profile.passes.get_mut(name).unwrap().gpu_time_ns = sample(i + 1);
        }
        sample(0)
    }
}
impl Drop for Pending {
    fn drop(&mut self) {
        self.readback.unmap();
    }
}
fn sample(bytes: &[u8], written: u32, slot: usize, period: f32) -> Option<u64> {
    if slot >= SLOTS || written & (1 << slot) == 0 {
        return None;
    }
    let bytes = bytes.get(slot * 16..slot * 16 + 16)?;
    let start = u64::from_le_bytes(bytes[..8].try_into().ok()?);
    let end = u64::from_le_bytes(bytes[8..].try_into().ok()?);
    duration(start, end, period)
}
fn duration(start: u64, end: u64, period: f32) -> Option<u64> {
    let ns = end.checked_sub(start)? as f64 * f64::from(period);
    (period.is_finite() && period > 0. && ns < u64::MAX as f64).then_some(ns as u64)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fixed_pass_slots_preserve_absence_and_reject_incomplete_reads() {
        assert_eq!(BUFFER_BYTES * 2, 416);
        let mut bytes = [0; BUFFER_BYTES as usize];
        let slot = Pass::Scene as usize + 1;
        bytes[slot * 16..slot * 16 + 8].copy_from_slice(&100_u64.to_le_bytes());
        bytes[slot * 16 + 8..slot * 16 + 16].copy_from_slice(&140_u64.to_le_bytes());
        assert_eq!(sample(&bytes, 1 << slot, slot, 2.5), Some(100));
        assert_eq!(sample(&bytes, 0, slot, 2.5), None);
        assert_eq!(sample(&bytes[..slot * 16 + 15], 1 << slot, slot, 2.5), None);
        assert_eq!(sample(&bytes, u32::MAX, SLOTS, 2.5), None);
        assert!(
            Profile::default()
                .passes
                .values()
                .all(|p| !p.executed && p.gpu_time_ns.is_none())
        );
    }
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
