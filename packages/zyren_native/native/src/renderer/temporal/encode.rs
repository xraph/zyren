use super::*;
use wgpu::util::DeviceExt;
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
struct Uniform {
    current: [f32; 16],
    previous: [f32; 16],
    unjittered: [f32; 16],
    params: [f32; 4],
    alpha: [f32; 4],
    raster: [f32; 4],
}
struct Draw {
    mesh: usize,
    key: MotionKey,
    uniform: wgpu::BindGroup,
    texture: wgpu::BindGroup,
    previous_vertices: wgpu::Buffer,
    previous_instances: Option<wgpu::Buffer>,
    current_pose: Option<wgpu::BindGroup>,
    previous_pose: Option<wgpu::BindGroup>,
}
impl System {
    pub fn targets(&self, frame: &Frame) -> Option<(&wgpu::Texture, &wgpu::Texture)> {
        frame.temporal.as_ref().map(|_| {
            let w = self.working.as_ref().expect("prepared temporal targets");
            (&w.color, &w.depth)
        })
    }
}
fn appearance_matches(a: &Mesh, b: &Mesh) -> bool {
    a.geometry == b.geometry
        && a.color == b.color
        && a.color_map == b.color_map
        && a.pbr == b.pbr
        && a.opacity == b.opacity
        && a.alpha_mode == b.alpha_mode
        && a.alpha_cutoff == b.alpha_cutoff
        && a.vertex_colors == b.vertex_colors
        && a.unlit == b.unlit
        && a.side == b.side
}
impl Renderer {
    pub(in crate::renderer) fn encode_temporal(
        &self,
        frame: &Frame,
        target: &wgpu::TextureView,
        encoder: &mut wgpu::CommandEncoder,
    ) {
        if frame.temporal.is_none() {
            return;
        }
        let system = &self.temporal;
        let pending = system.pending.as_ref().unwrap();
        let working = system.working.as_ref().unwrap();
        let pipelines = system.pipelines.as_ref().unwrap();
        let candidate = &pending.candidate;
        let prior = system.views.get(&pending.view).map(|h| &h.current);
        let mut draws = Vec::new();
        for (index, (mesh, identity)) in frame
            .meshes
            .iter()
            .zip(&candidate.input.identities)
            .enumerate()
        {
            if !mesh.color_visible {
                continue;
            }
            let current = &candidate.meshes[&identity[0]];
            let previous = prior
                .and_then(|s| s.meshes.get(&identity[0]))
                .filter(|old| {
                    old.logical_geometry == identity[1]
                        && old.vertices.size() == current.vertices.size()
                        && old.pose.is_some() == current.pose.is_some()
                        && old.instances.as_ref().map(|b| b.size())
                            == current.instances.as_ref().map(|b| b.size())
                        && old.source.as_ref().map(|b| b.size())
                            == current.source.as_ref().map(|b| b.size())
                });
            let valid =
                pending.valid && previous.is_some_and(|old| appearance_matches(mesh, &old.mesh));
            let geometry = &self.geometries[&mesh.geometry];
            let vertices = self.resources.geometry(geometry.key).0;
            let instances = if mesh.instances == 0 {
                None
            } else {
                Some(
                    self.resources
                        .graph_buffer(self.instances[&mesh.instances].key)
                        .unwrap(),
                )
            };
            let current_mvp = glam::Mat4::from_cols_array(&candidate.vp)
                * glam::Mat4::from_cols_array(&mesh.model);
            let previous_mvp = previous.map_or(current_mvp, |p| {
                glam::Mat4::from_cols_array(&prior.unwrap().unjittered_vp)
                    * glam::Mat4::from_cols_array(&p.mesh.model)
            });
            let reactive = mesh.transmissive()
                || mesh.alpha_mode == 2
                || !mesh.depth_test
                || !mesh.writes_depth();
            let parameters = Uniform {
                current: current_mvp.to_cols_array(),
                previous: previous_mvp.to_cols_array(),
                unjittered: (glam::Mat4::from_cols_array(&frame.view_projection)
                    * glam::Mat4::from_cols_array(&mesh.model))
                .to_cols_array(),
                params: [
                    f32::from(valid),
                    previous.map_or(0., |p| p.mesh.instance_count as f32),
                    mesh.alpha_mode as f32,
                    mesh.alpha_cutoff,
                ],
                alpha: [
                    mesh.opacity,
                    mesh.color_map.as_ref().map_or(0., |m| m.uv_set as f32),
                    f32::from(reactive),
                    f32::from(mesh.color_map.is_some()),
                ],
                raster: [mesh.side as f32, 0., 0., 0.],
            };
            let buffer = self
                .device
                .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                    label: Some("temporal motion parameters"),
                    contents: bytemuck::bytes_of(&parameters),
                    usage: wgpu::BufferUsages::UNIFORM,
                });
            let uniform = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("temporal motion parameters"),
                layout: &pipelines.uniform,
                entries: &[wgpu::BindGroupEntry {
                    binding: 0,
                    resource: buffer.as_entire_binding(),
                }],
            });
            let (view, sampler) = mesh.color_map.as_ref().map_or_else(
                || (pipelines.white.clone(), pipelines.sampler.clone()),
                |m| self.texture_parts(m),
            );
            let texture = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("temporal alpha coverage"),
                layout: &pipelines.texture,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(&view),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::Sampler(&sampler),
                    },
                ],
            });
            let bind_pose = |source: &wgpu::Buffer, pose: &wgpu::Buffer| {
                self.device.create_bind_group(&wgpu::BindGroupDescriptor {
                    label: Some("temporal mesh pose"),
                    layout: &pipelines.deformation,
                    entries: &[
                        wgpu::BindGroupEntry {
                            binding: 0,
                            resource: source.as_entire_binding(),
                        },
                        wgpu::BindGroupEntry {
                            binding: 1,
                            resource: pose.as_entire_binding(),
                        },
                    ],
                })
            };
            let (current_pose, previous_pose) = if mesh.pose != 0 {
                let source = self.resources.geometry_deformation(geometry.key).unwrap();
                let pose = self
                    .resources
                    .graph_buffer(self.poses[&mesh.pose].key)
                    .unwrap();
                (
                    Some(bind_pose(source, &pose)),
                    Some(bind_pose(
                        previous.and_then(|p| p.source.as_ref()).unwrap_or(source),
                        previous.and_then(|p| p.pose.as_ref()).unwrap_or(&pose),
                    )),
                )
            } else {
                (None, None)
            };
            draws.push(Draw {
                mesh: index,
                key: MotionKey::new(mesh),
                uniform,
                texture,
                previous_vertices: previous.map_or(vertices, |p| &p.vertices).clone(),
                previous_instances: previous
                    .and_then(|p| p.instances.as_ref())
                    .or(instances.as_ref())
                    .cloned(),
                current_pose,
                previous_pose,
            });
        }
        // Reactive overlays follow valid opaque motion so they cannot inherit it.
        draws.sort_by_key(|draw| {
            let mesh = &frame.meshes[draw.mesh];
            (
                mesh.alpha_mode == 2 || !mesh.writes_depth() || !mesh.depth_test,
                mesh.render_order,
                draw.mesh,
            )
        });
        let motion_view = working.motion.create_view(&Default::default());
        let depth_view = working.depth.create_view(&Default::default());
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("temporal motion"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &motion_view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: &depth_view,
                    depth_ops: None,
                    stencil_ops: None,
                }),
                ..Default::default()
            });
            for draw in &draws {
                let mesh = &frame.meshes[draw.mesh];
                let geometry = &self.geometries[&mesh.geometry];
                let (vertices, indices, count, uv, index_format) =
                    self.resources.geometry(geometry.key);
                pass.set_pipeline(pipelines.motion(draw.key));
                pass.set_bind_group(0, &draw.uniform, &[]);
                pass.set_bind_group(1, &draw.texture, &[]);
                pass.set_vertex_buffer(0, vertices.slice(..));
                pass.set_vertex_buffer(1, draw.previous_vertices.slice(..));
                let mut slot = 2;
                if draw.key.textured {
                    pass.set_vertex_buffer(slot, uv.unwrap().slice(..));
                    slot += 1;
                }
                if draw.key.colored {
                    pass.set_vertex_buffer(
                        slot,
                        self.resources
                            .geometry_colors(geometry.key)
                            .unwrap()
                            .slice(..),
                    );
                    slot += 1;
                }
                if draw.key.instanced {
                    pass.set_vertex_buffer(
                        slot,
                        self.resources
                            .graph_buffer(self.instances[&mesh.instances].key)
                            .unwrap()
                            .slice(..),
                    );
                    pass.set_vertex_buffer(
                        slot + 1,
                        draw.previous_instances.as_ref().unwrap().slice(..),
                    );
                }
                if let (Some(current), Some(previous)) = (&draw.current_pose, &draw.previous_pose) {
                    pass.set_bind_group(2, current, &[]);
                    pass.set_bind_group(3, previous, &[]);
                }
                pass.set_index_buffer(indices.slice(..), index_format);
                pass.draw_indexed(0..count, 0, 0..mesh.instance_count);
            }
        }
        let history = prior
            .map_or(&working.color, |p| &p.color)
            .create_view(&Default::default());
        let history_depth = prior
            .map_or(&working.motion, |p| &p.depth)
            .create_view(&Default::default());
        let current = working.color.create_view(&Default::default());
        let values = [
            candidate
                .input
                .history_weight
                .min((candidate.frame - 1) as f32 / candidate.frame as f32),
            candidate.input.depth_tolerance,
            f32::from(pending.valid),
            0.,
        ];
        let params = self
            .device
            .create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some("temporal resolve parameters"),
                contents: bytemuck::cast_slice(&values),
                usage: wgpu::BufferUsages::UNIFORM,
            });
        let mut entries: Vec<_> = [
            &current,
            &motion_view,
            &depth_view,
            &history,
            &history_depth,
        ]
        .into_iter()
        .enumerate()
        .map(|(i, view)| wgpu::BindGroupEntry {
            binding: i as u32,
            resource: wgpu::BindingResource::TextureView(view),
        })
        .collect();
        entries.push(wgpu::BindGroupEntry {
            binding: 5,
            resource: params.as_entire_binding(),
        });
        let binding = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("temporal resolve"),
            layout: &pipelines.resolve_layout,
            entries: &entries,
        });
        let history_target = candidate.color.create_view(&Default::default());
        let depth_target = candidate.depth.create_view(&Default::default());
        {
            let targets = [target, &history_target, &depth_target].map(|view| {
                Some(wgpu::RenderPassColorAttachment {
                    view,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })
            });
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("temporal reconstruction"),
                color_attachments: &targets,
                ..Default::default()
            });
            pass.set_pipeline(&pipelines.resolve);
            pass.set_bind_group(0, &binding, &[]);
            pass.draw(0..3, 0..1);
        }
        for (source, target) in &pending.copies {
            encoder.copy_buffer_to_buffer(source, 0, target, 0, source.size());
        }
        self.last_scene_draws
            .set(self.last_scene_draws.get() + draws.len() as u64 + 1);
    }
}
