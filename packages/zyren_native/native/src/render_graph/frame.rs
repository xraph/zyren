use super::{GraphError, GraphStore, ScopedGraph, descriptor::Description, key};
use crate::resources::{ResourceStore, registry::ResourceKey};
use std::sync::Arc;

pub(crate) struct FrameGraph {
    graph: Arc<ScopedGraph>,
    pub scene_color: wgpu::Texture,
    pub output: wgpu::Texture,
    pub scene_resource: ResourceKey,
}
impl FrameGraph {
    pub fn resources(&self) -> &[ResourceKey] {
        &self.graph.resources
    }
    pub fn encode(&self, encoder: &mut wgpu::CommandEncoder) {
        self.graph.encode_range(
            encoder,
            self.graph.scene_pass_index..self.graph.passes.len(),
        );
    }
    pub fn encode_before(&self, encoder: &mut wgpu::CommandEncoder) {
        self.graph
            .encode_range(encoder, 0..self.graph.scene_pass_index);
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
                        wgpu::TextureFormat::Rgba8Unorm
                            | wgpu::TextureFormat::Rgba8UnormSrgb
                            | wgpu::TextureFormat::Rgba16Float
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
            scene_resource: graph.scene_resource.expect("frame scene resource"),
            graph,
        })
    }
}

type FramePacket<'a> = (
    &'a [u8],
    Option<ResourceKey>,
    Vec<(u32, ResourceKey)>,
    Option<crate::lighting::Environment>,
);

pub(crate) fn decode_packet(bytes: &[u8]) -> Result<FramePacket<'_>, String> {
    if !bytes.starts_with(&3_u32.to_le_bytes()) {
        return Ok((bytes, None, vec![], None));
    }
    if bytes.len() < 48 || bytes.len() > 66 * 1024 * 1024 + 184 + 4096 * 40 {
        return Err("Invalid scene envelope length".into());
    }
    let u32_at = |offset| u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
    let u64_at = |offset| u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap());
    let read_key = |offset| -> Result<ResourceKey, String> {
        let fields = std::array::from_fn(|i| u64_at(offset + i * 8));
        if fields.iter().any(|value| *value > i64::MAX as u64) {
            return Err("Invalid scene envelope key".into());
        }
        Ok(key(fields))
    };
    let (offset, graph, materials, environment) = match u32_at(4) {
        1 => (48, Some(read_key(16)?), vec![], None),
        version @ (2 | 3) if bytes.len() >= 56 => {
            let base = if version == 3 { 184 } else { 56 };
            let count = u32_at(16) as usize;
            let has_graph = u32_at(20);
            if count > 4096 || has_graph > 1 || bytes.len() < base + count * 40 {
                return Err("Invalid mesh shader envelope".into());
            }
            let graph = if has_graph == 1 {
                Some(read_key(24)?)
            } else {
                if bytes[24..56].iter().any(|byte| *byte != 0) {
                    return Err("Unexpected graph key".into());
                }
                None
            };
            let mut seen = std::collections::HashSet::new();
            let mut materials = Vec::with_capacity(count);
            for i in 0..count {
                let offset = base + i * 40;
                let index = u32_at(offset);
                if index >= 4096 || u32_at(offset + 4) != 0 || !seen.insert(index) {
                    return Err("Invalid or duplicate mesh shader index".into());
                }
                materials.push((index, read_key(offset + 8)?));
            }
            let environment = if version == 3 {
                if bytes[172..184].iter().any(|byte| *byte != 0) {
                    return Err("Invalid environment reserved bytes".into());
                }
                let float_at =
                    |offset| f32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
                let value = crate::lighting::Environment {
                    textures: [read_key(56)?, read_key(88)?, read_key(120)?],
                    intensity: float_at(152),
                    rotation: std::array::from_fn(|i| float_at(156 + i * 4)),
                };
                value.validate()?;
                Some(value)
            } else {
                None
            };
            (base + count * 40, graph, materials, environment)
        }
        _ => return Err("Unsupported scene envelope".into()),
    };
    if bytes.len() < offset + 24
        || bytes.len() - offset > 66 * 1024 * 1024
        || u64_at(8) != (bytes.len() - offset) as u64
        || u32_at(offset) != 2
    {
        return Err("Invalid enclosed scene packet".into());
    }
    Ok((&bytes[offset..], graph, materials, environment))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn environment_envelope_validates_all_fields_and_composes_with_graphs_and_materials() {
        let mut bytes = vec![0; 184 + 40 + 24];
        bytes[0..4].copy_from_slice(&3_u32.to_le_bytes());
        bytes[4..8].copy_from_slice(&3_u32.to_le_bytes());
        bytes[8..16].copy_from_slice(&24_u64.to_le_bytes());
        bytes[16..20].copy_from_slice(&1_u32.to_le_bytes());
        bytes[20..24].copy_from_slice(&1_u32.to_le_bytes());
        for (offset, value) in [(24, 1_u64), (56, 2), (88, 3), (120, 4), (192, 5)] {
            bytes[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
        }
        bytes[152..156].copy_from_slice(&0.5_f32.to_le_bytes());
        bytes[168..172].copy_from_slice(&1_f32.to_le_bytes());
        bytes[224..228].copy_from_slice(&2_u32.to_le_bytes());
        let (scene, graph, materials, environment) = decode_packet(&bytes).unwrap();
        assert_eq!(scene.len(), 24);
        assert_eq!(graph.unwrap().renderer, 1);
        assert_eq!(materials[0].1.renderer, 5);
        let environment = environment.unwrap();
        assert_eq!(environment.textures.map(|key| key.renderer), [2, 3, 4]);
        assert_eq!(environment.intensity, 0.5);
        assert_eq!(environment.rotation, [0., 0., 0., 1.]);
        for length in 4..bytes.len() {
            assert!(decode_packet(&bytes[..length]).is_err(), "length {length}");
        }
        for offset in [56, 64, 72, 80, 88, 96, 104, 112, 120, 128, 136, 144] {
            let mut invalid = bytes.clone();
            invalid[offset..offset + 8].copy_from_slice(&u64::MAX.to_le_bytes());
            assert!(decode_packet(&invalid).is_err(), "key at {offset}");
        }
        for offset in 172..184 {
            let mut invalid = bytes.clone();
            invalid[offset] = 1;
            assert!(decode_packet(&invalid).is_err(), "reserved {offset}");
        }
        for offset in [152, 156, 160, 164, 168] {
            for value in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, -2., 1_000_001.] {
                let mut invalid = bytes.clone();
                invalid[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
                assert!(
                    decode_packet(&invalid).is_err(),
                    "float at {offset}: {value}"
                );
            }
        }
        bytes[168..172].fill(0);
        assert!(decode_packet(&bytes).is_err(), "zero quaternion");
    }

    #[test]
    fn mesh_envelope_rejects_duplicate_indices_reserved_fields_and_truncation() {
        let mut bytes = vec![0; 56 + 2 * 40 + 24];
        bytes[0..4].copy_from_slice(&3_u32.to_le_bytes());
        bytes[4..8].copy_from_slice(&2_u32.to_le_bytes());
        bytes[8..16].copy_from_slice(&24_u64.to_le_bytes());
        bytes[16..20].copy_from_slice(&2_u32.to_le_bytes());
        bytes[96..100].copy_from_slice(&1_u32.to_le_bytes());
        bytes[136..140].copy_from_slice(&2_u32.to_le_bytes());
        let (scene, graph, materials, environment) = decode_packet(&bytes).unwrap();
        assert_eq!(scene.len(), 24);
        assert!(environment.is_none());
        assert!(graph.is_none());
        assert_eq!(materials.len(), 2);
        for length in 4..bytes.len() {
            assert!(decode_packet(&bytes[..length]).is_err());
        }
        for (offset, value) in [
            (8, 25_u64),
            (16, 4097),
            (20, 2),
            (24, 1),
            (56, 4096),
            (60, 1),
            (64, u64::MAX),
            (96, 0),
            (136, 3),
        ] {
            let mut invalid = bytes.clone();
            invalid[offset..offset + 8].copy_from_slice(&value.to_le_bytes());
            assert!(decode_packet(&invalid).is_err(), "offset {offset}");
        }
        bytes[20..24].copy_from_slice(&1_u32.to_le_bytes());
        bytes[24..32].copy_from_slice(&7_u64.to_le_bytes());
        assert_eq!(decode_packet(&bytes).unwrap().1.unwrap().renderer, 7);
    }
    #[test]
    fn frame_envelope_rejects_truncation_lengths_nested_packets_and_large_keys() {
        let mut bytes = vec![0; 72];
        bytes[0..4].copy_from_slice(&3_u32.to_le_bytes());
        bytes[4..8].copy_from_slice(&1_u32.to_le_bytes());
        bytes[8..16].copy_from_slice(&24_u64.to_le_bytes());
        bytes[16..24].copy_from_slice(&1_u64.to_le_bytes());
        bytes[48..52].copy_from_slice(&2_u32.to_le_bytes());
        let (scene, key, materials, environment) = decode_packet(&bytes).unwrap();
        assert_eq!(scene.len(), 24);
        assert!(environment.is_none());
        assert!(materials.is_empty());
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
