use super::{GraphError, GraphStore, PipelineKind, ResourceKey, ResourceStore, scoped};
use serde_json::{Value, json};

impl GraphStore {
    pub(super) fn execute(
        &self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        resources: &mut ResourceStore,
        key: ResourceKey,
    ) -> Result<Value, GraphError> {
        let graph = self.registry.resolve(key)?;
        if graph.frame.is_some() {
            return Err(GraphError::new(
                "invalidDescriptor",
                "Submit this graph with a scene frame",
            ));
        }
        let mut dispatches = 0;
        let mut draws = 0;
        let commands = scoped(device, "execute", || {
            let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("custom render graph"),
            });
            let counts = graph.encode(&mut encoder);
            dispatches = counts.0;
            draws = counts.1;
            Ok(encoder.finish())
        })?;
        scoped(device, "submit", || {
            resources
                .execute_graph(device, queue, &graph.resources, commands)
                .map_err(Into::into)
        })?;
        Ok(json!({"passes": graph.passes.len(), "dispatches": dispatches, "drawCalls": draws}))
    }
}

impl super::ScopedGraph {
    pub(super) fn encode(&self, encoder: &mut wgpu::CommandEncoder) -> (u32, u32) {
        self.encode_range(encoder, 0..self.passes.len())
    }
    pub(super) fn encode_range(
        &self,
        encoder: &mut wgpu::CommandEncoder,
        range: std::ops::Range<usize>,
    ) -> (u32, u32) {
        let mut dispatches = 0;
        let mut draws = 0;
        for pass in &self.passes[range] {
            match &pass.pipeline.kind {
                PipelineKind::Compute(pipeline) => {
                    let mut encoder = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                        label: Some(&pass.name),
                        timestamp_writes: None,
                    });
                    encoder.set_pipeline(pipeline);
                    for (index, group) in pass.groups.iter().enumerate() {
                        encoder.set_bind_group(index as u32, group, &[]);
                    }
                    encoder.dispatch_workgroups(
                        pass.workgroups[0],
                        pass.workgroups[1],
                        pass.workgroups[2],
                    );
                    dispatches += 1;
                }
                PipelineKind::Render(pipeline) => {
                    let (view, ops) = pass.color.as_ref().unwrap();
                    let colors = [Some(wgpu::RenderPassColorAttachment {
                        view,
                        resolve_target: None,
                        depth_slice: None,
                        ops: *ops,
                    })];
                    let mut encoder = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: Some(&pass.name),
                        color_attachments: &colors,
                        ..Default::default()
                    });
                    encoder.set_pipeline(pipeline);
                    for (index, group) in pass.groups.iter().enumerate() {
                        encoder.set_bind_group(index as u32, group, &[]);
                    }
                    encoder.draw(0..pass.vertex_count, 0..pass.instance_count);
                    draws += 1;
                }
            }
        }
        (dispatches, draws)
    }
}
