use super::{Renderer, timing};
use crate::{resources::registry::ResourceKey, scene::Frame};
use std::{cell::Cell, collections::HashSet};

pub(super) const BYTES: u64 = 128 * 128 * 8;
pub(super) struct Table {
    pub key: ResourceKey,
    pub texture: wgpu::Texture,
    pipeline: wgpu::RenderPipeline,
    initialized: bool,
}
#[derive(Default)]
pub(super) struct System {
    pub table: Option<Table>,
    owners: HashSet<u64>,
    pending: Option<u64>,
    generation_encoded: Cell<bool>,
}
fn needed(frame: &Frame) -> bool {
    frame.meshes.iter().any(|m| m.pbr.is_some())
        || frame
            .binary
            .as_ref()
            .is_some_and(|v| v.meshes.iter().any(|m| m.pbr.is_some()))
}
fn fallback_needed(frame: &Frame) -> bool {
    frame.environment.is_none()
        && frame.settings.environment.is_none()
        && frame.meshes.iter().any(|m| m.pbr.is_some())
}
impl Renderer {
    pub(super) fn prepare_energy_lut(&mut self, frame: &Frame) -> Result<(), String> {
        let state = self.state.as_mut().unwrap();
        state.energy_lut.pending = None;
        state.energy_lut.generation_encoded.set(false);
        if !needed(frame) {
            return self.retire_energy_lut();
        }
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        state.energy_lut.pending = Some(view);
        if state.energy_lut.table.is_some() || !fallback_needed(frame) {
            return Ok(());
        }
        state
            .resources
            .check_scene_capacity(BYTES, 1)
            .map_err(|e| e.to_string())?;
        let (key, texture) = state
            .resources
            .create_frame_target(&state.device, [128, 128], wgpu::TextureFormat::Rgba16Float)
            .map_err(|e| e.to_string())?;
        let validation = state.device.push_error_scope(wgpu::ErrorFilter::Validation);
        let memory = state
            .device
            .push_error_scope(wgpu::ErrorFilter::OutOfMemory);
        let internal = state.device.push_error_scope(wgpu::ErrorFilter::Internal);
        let shader = state
            .device
            .create_shader_module(wgpu::ShaderModuleDescriptor {
                label: Some("GGX directional energy integral"),
                source: wgpu::ShaderSource::Wgsl(
                    concat!(
                        include_str!("ggx_energy.wgsl"),
                        "\n",
                        include_str!("energy_lut.wgsl")
                    )
                    .into(),
                ),
            });
        let pipeline = state
            .device
            .create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("GGX directional energy integral"),
                layout: None,
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some("vs_energy"),
                    compilation_options: Default::default(),
                    buffers: &[],
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some("fs_energy"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format: wgpu::TextureFormat::Rgba16Float,
                        blend: None,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: Default::default(),
                depth_stencil: None,
                multisample: Default::default(),
                multiview_mask: None,
                cache: None,
            });
        let mut error = None;
        for scope in [internal, memory, validation] {
            if let Some(failure) = pollster::block_on(scope.pop()) {
                error = Some(failure.to_string());
            }
        }
        if let Some(error) = error {
            drop(pipeline);
            drop(texture);
            state
                .resources
                .release_scene_resource(key)
                .map_err(|e| e.to_string())?;
            return Err(error);
        }
        state.energy_lut.table = Some(Table {
            key,
            texture,
            pipeline,
            initialized: false,
        });
        Ok(())
    }
    pub(super) fn commit_energy_lut(&mut self, frame: &Frame) -> Result<(), String> {
        let view = frame.binary.as_ref().map_or(0, |v| v.view);
        if needed(frame) {
            self.energy_lut.owners.insert(view);
        } else {
            self.energy_lut.owners.remove(&view);
        }
        self.energy_lut.pending = None;
        self.retire_energy_lut()
    }
    pub(super) fn close_energy_lut(&mut self, view: u64) -> Result<(), String> {
        self.energy_lut.owners.remove(&view);
        if self.energy_lut.pending == Some(view) {
            self.energy_lut.pending = None;
        }
        self.retire_energy_lut()
    }
    fn retire_energy_lut(&mut self) -> Result<(), String> {
        if !self.energy_lut.owners.is_empty()
            || self.energy_lut.pending.is_some()
            || self
                .staging
                .values()
                .any(|v| v.meshes.iter().any(|m| m.pbr.is_some()))
        {
            return Ok(());
        }
        if let Some(table) = self.energy_lut.table.take() {
            self.draw_cache
                .borrow_mut()
                .invalidate_textures(&[&table.texture]);
            let key = table.key;
            drop(table);
            self.resources
                .release_scene_resource(key)
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
    pub(super) fn encode_energy_lut(&self, encoder: &mut wgpu::CommandEncoder, frame: &Frame) {
        self.energy_lut.generation_encoded.set(false);
        if !fallback_needed(frame) {
            return;
        }
        let Some(table) = self.energy_lut.table.as_ref().filter(|t| !t.initialized) else {
            return;
        };
        self.begin_pass(encoder, timing::Pass::EnergyLut);
        let view = table.texture.create_view(&Default::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("GGX directional energy integral"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    depth_slice: None,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&table.pipeline);
            pass.draw(0..3, 0..1);
        }
        self.profile
            .borrow_mut()
            .passes
            .get_mut("energyLut")
            .unwrap()
            .draw_calls = Some(1);
        self.end_pass(encoder, timing::Pass::EnergyLut);
        self.energy_lut.generation_encoded.set(true);
    }
    pub(super) fn energy_lut_submitted(&mut self) {
        if !self.energy_lut.generation_encoded.replace(false) {
            return;
        }
        if let Some(table) = &mut self.energy_lut.table {
            table.initialized = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn frame(view: u64) -> Frame {
        let mut frame: Frame = serde_json::from_value(json!({
            "version":1, "view_projection":glam::Mat4::IDENTITY.to_cols_array(),
            "background":[0,0,0], "light_direction":[0,0,1], "ambient":0,
            "geometries":[{"id":1,"positions":[[-1,-1,0],[1,-1,0],[0,1,0]],
                "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
            "meshes":[{"geometry":1,"model":glam::Mat4::IDENTITY.to_cols_array(),
                "color":[1,1,1],"unlit":false,
                "pbr":{"metallic":1,"roughness":1,"emissive":[0,0,0]}}]
        }))
        .unwrap();
        frame.binary = Some(crate::scene_packet::ViewState {
            view,
            revision: 1,
            retained: [1].into_iter().collect(),
            meshes: frame.meshes.clone(),
            retained_textures: HashSet::new(),
            retained_instances: HashSet::new(),
            retained_poses: HashSet::new(),
        });
        frame
    }
    #[test]
    #[ignore = "requires a native GPU"]
    fn lazy_lut_generation_pending_retry_and_all_view_release_are_accounted() {
        let mut renderer = pollster::block_on(Renderer::new()).unwrap();
        let baseline = renderer.scene_resource_stats().0;
        let first = frame(1);
        let mut supplied = first.clone();
        // Preparation only needs source presence. Full binding validity and
        // supplied-environment rendering are covered by the native Dart test.
        supplied.environment = Some(crate::lighting::Environment {
            textures: [ResourceKey {
                renderer: 0,
                device_generation: 0,
                slot: 0,
                slot_generation: 0,
            }; 3],
            intensity: 1.,
            rotation: [0., 0., 0., 1.],
        });
        renderer.prepare_energy_lut(&supplied).unwrap();
        renderer.commit_energy_lut(&supplied).unwrap();
        assert!(renderer.energy_lut.table.is_none());
        assert_eq!(renderer.scene_resource_stats().0, baseline);
        renderer.prepare_energy_lut(&first).unwrap();
        let key = renderer.energy_lut.table.as_ref().unwrap().key;
        assert_eq!(renderer.scene_resource_stats().0 - baseline, BYTES);
        assert!(!renderer.energy_lut.table.as_ref().unwrap().initialized);
        renderer.prepare_energy_lut(&supplied).unwrap();
        let mut skipped = renderer.device.create_command_encoder(&Default::default());
        renderer.encode_energy_lut(&mut skipped, &supplied);
        renderer.energy_lut_submitted();
        assert!(!renderer.energy_lut.table.as_ref().unwrap().initialized);
        drop(skipped);
        // Aborted preparation can close its candidate without publishing it.
        renderer.close_scene_view(1).unwrap();
        assert!(renderer.energy_lut.table.is_none());
        assert!(renderer.resources.graph_texture(key).is_err());
        renderer.render(&first, 9, 9).unwrap();
        assert!(renderer.energy_lut.table.as_ref().unwrap().initialized);
        assert_eq!(
            renderer.profile.borrow().passes["energyLut"].draw_calls,
            Some(1)
        );
        let key = renderer.energy_lut.table.as_ref().unwrap().key;
        let mut second = frame(2);
        second.geometries.clear();
        renderer.render(&second, 9, 9).unwrap();
        assert!(!renderer.profile.borrow().passes["energyLut"].executed);
        // A culled frame retains its source packet and therefore its PBR need.
        second.meshes.clear();
        renderer.render(&second, 9, 9).unwrap();
        let texture = renderer.energy_lut.table.as_ref().unwrap().texture.clone();
        assert!(renderer.draw_cache.borrow().references_texture(&texture));
        renderer.close_scene_view(1).unwrap();
        assert_eq!(renderer.energy_lut.table.as_ref().unwrap().key, key);
        renderer.close_scene_view(2).unwrap();
        assert!(!renderer.draw_cache.borrow().references_texture(&texture));
        drop(texture);
        assert!(renderer.energy_lut.table.is_none());
        assert!(renderer.resources.graph_texture(key).is_err());
        assert_eq!(renderer.scene_resource_stats().0, baseline);
        // A failed retry never marks an unsubmitted candidate initialized.
        renderer.prepare_energy_lut(&first).unwrap();
        let mut invalid = first.clone();
        invalid.meshes[0].geometry = 99;
        assert!(renderer.render(&invalid, 9, 9).is_err());
        assert!(!renderer.energy_lut.table.as_ref().unwrap().initialized);
        renderer.render(&first, 9, 9).unwrap();
        assert!(renderer.energy_lut.table.as_ref().unwrap().initialized);
        renderer.close_scene_view(1).unwrap();
        assert_eq!(renderer.scene_resource_stats().0, baseline);
    }
}
