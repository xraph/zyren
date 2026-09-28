use super::Renderer;
use crate::{
    render_graph::{FrameGraph, PreparedMaterial},
    scene::Frame,
};

impl Renderer {
    pub(super) fn prepare_materials(
        &mut self,
        frame: &Frame,
        format: wgpu::TextureFormat,
        graph: Option<&FrameGraph>,
    ) -> Result<Vec<Option<PreparedMaterial>>, String> {
        if let Some(failure) = &self.failure {
            return Err(failure.clone());
        }
        let format = graph.map_or(format, |g| g.scene_color.format());
        let state = self.state.as_mut().unwrap();
        frame
            .meshes
            .iter()
            .map(|mesh| {
                let Some(key) = mesh.shader else {
                    return Ok(None);
                };
                mesh.validate_material()?;
                let material = state
                    .graphs
                    .meshes
                    .prepare(&state.device, key, mesh, format)
                    .map_err(|error| {
                        if error.is_device_failure() {
                            state.failure = Some(error.to_string());
                        }
                        error.to_string()
                    })?;
                if graph.is_some_and(|g| material.resources.contains(&g.scene_resource)) {
                    return Err("Mesh shader cannot sample the scene color attachment".into());
                }
                let geometry = frame
                    .geometries
                    .iter()
                    .find(|g| g.id == mesh.geometry)
                    .or_else(|| {
                        state
                            .geometries
                            .get(&mesh.geometry)
                            .map(|g| g.recipe.as_ref())
                    })
                    .ok_or("Mesh shader geometry is absent")?;
                if material.uv && geometry.uv0.is_empty() && geometry.uv1.is_empty() {
                    return Err("Mesh shader requires UV geometry".into());
                }
                Ok(Some(material))
            })
            .collect()
    }
}
