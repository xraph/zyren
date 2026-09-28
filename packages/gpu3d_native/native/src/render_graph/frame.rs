use super::{GraphError, GraphStore, ScopedGraph, descriptor::Description, key};
use crate::resources::{ResourceStore, registry::ResourceKey};
use std::sync::Arc;

pub(crate) struct FrameGraph {
    graph: Arc<ScopedGraph>,
    pub scene_color: wgpu::Texture,
    pub output: wgpu::Texture,
}
impl FrameGraph {
    pub fn resources(&self) -> &[ResourceKey] {
        &self.graph.resources
    }
    pub fn encode(&self, encoder: &mut wgpu::CommandEncoder) {
        self.graph.encode(encoder);
    }
}
impl GraphStore {
    pub(super) fn prepare_frame(
        &self,
        resources: &ResourceStore,
        description: &Description,
    ) -> Result<Option<(wgpu::Texture, wgpu::Texture)>, GraphError> {
        let (scene, output) = match (description.scene_color, description.output) {
            (None, None) => return Ok(None),
            (Some(scene), Some(output)) => (scene, output),
            _ => {
                return Err(GraphError::new(
                    "invalidDescriptor",
                    "A frame graph requires sceneColor and output",
                ));
            }
        };
        if ![scene, output]
            .iter()
            .all(|key| description.resources.iter().any(|r| &r.key == key))
        {
            return Err(GraphError::new(
                "invalidDescriptor",
                "Frame texture is absent from resource table",
            ));
        }
        let scene = resources.graph_texture(key(scene))?;
        let output = resources.graph_texture(key(output))?;
        if !scene
            .usage()
            .contains(wgpu::TextureUsages::RENDER_ATTACHMENT)
            || !output
                .usage()
                .contains(wgpu::TextureUsages::TEXTURE_BINDING)
            || scene.size() != output.size()
            || [&scene, &output].iter().any(|t| {
                t.mip_level_count() != 1
                    || t.sample_count() != 1
                    || !matches!(
                        t.format(),
                        wgpu::TextureFormat::Rgba8Unorm | wgpu::TextureFormat::Rgba8UnormSrgb
                    )
            })
        {
            return Err(GraphError::new(
                "invalidBinding",
                "Frame textures need matching dimensions, one mip, renderable scene color and sampled output",
            ));
        }
        Ok(Some((scene, output)))
    }
    pub(crate) fn frame(
        &self,
        key: ResourceKey,
        width: u32,
        height: u32,
    ) -> Result<FrameGraph, String> {
        let graph = self
            .registry
            .resolve(key)
            .map_err(|e| e.to_string())?
            .clone();
        let (scene_color, output) = graph
            .frame
            .as_ref()
            .ok_or("Graph has no scene frame contract")?;
        if scene_color.width() != width || scene_color.height() != height {
            return Err("Frame graph dimensions differ from the submitted frame".into());
        }
        Ok(FrameGraph {
            scene_color: scene_color.clone(),
            output: output.clone(),
            graph,
        })
    }
}

/// A bounded envelope carries one graph key and an unchanged binary scene packet.
/// No recursion or legacy JSON is admitted inside it.
pub(crate) fn decode_packet(bytes: &[u8]) -> Result<(&[u8], Option<ResourceKey>), String> {
    if !bytes.starts_with(&3_u32.to_le_bytes()) {
        return Ok((bytes, None));
    }
    if bytes.len() < 72
        || bytes.len() > 66 * 1024 * 1024 + 48
        || bytes[4..8] != 1_u32.to_le_bytes()
        || u64::from_le_bytes(bytes[8..16].try_into().unwrap()) != (bytes.len() - 48) as u64
        || bytes[48..52] != 2_u32.to_le_bytes()
    {
        return Err("Invalid frame graph envelope".into());
    }
    let fields: [u64; 4] = std::array::from_fn(|i| {
        u64::from_le_bytes(bytes[16 + i * 8..24 + i * 8].try_into().unwrap())
    });
    if fields.iter().any(|value| *value > i64::MAX as u64) {
        return Err("Invalid frame graph key".into());
    }
    Ok((&bytes[48..], Some(key(fields))))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn frame_envelope_rejects_truncation_lengths_nested_packets_and_large_keys() {
        let mut bytes = vec![0; 72];
        bytes[0..4].copy_from_slice(&3_u32.to_le_bytes());
        bytes[4..8].copy_from_slice(&1_u32.to_le_bytes());
        bytes[8..16].copy_from_slice(&24_u64.to_le_bytes());
        bytes[16..24].copy_from_slice(&1_u64.to_le_bytes());
        bytes[48..52].copy_from_slice(&2_u32.to_le_bytes());
        let (scene, key) = decode_packet(&bytes).unwrap();
        assert_eq!(scene.len(), 24);
        assert_eq!(key.unwrap().renderer, 1);
        for length in 4..bytes.len() {
            assert!(decode_packet(&bytes[..length]).is_err());
        }
        for (offset, value) in [(4, 2_u64), (8, 23), (16, u64::MAX), (48, 3)] {
            let mut invalid = bytes.clone();
            invalid[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
            assert!(decode_packet(&invalid).is_err());
        }
        assert!(decode_packet(&2_u32.to_le_bytes()).unwrap().1.is_none());
    }
}
