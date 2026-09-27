use crate::scene::{
    ColorMap, Frame, Geometry, MAX_INDICES, MAX_MESHES, MAX_VERTICES, Mesh, SceneTexture,
};
use std::collections::HashSet;

#[derive(Clone, PartialEq)]
pub struct ViewState {
    pub view: u64,
    pub revision: u64,
    pub retained: HashSet<u32>,
    pub meshes: Vec<Mesh>,
    pub retained_textures: HashSet<u32>,
}
pub struct ScenePacket {
    view: u64,
    revision: u64,
    base: u64,
    retained: HashSet<u32>,
    geometries: Vec<Geometry>,
    mesh_count: usize,
    updates: Vec<(usize, Mesh)>,
    view_projection: [f32; 16],
    background: [f64; 3],
    light_direction: [f32; 3],
    ambient: f32,
    retained_textures: HashSet<u32>,
    textures: Vec<SceneTexture>,
}
struct Reader<'a> {
    data: &'a [u8],
    offset: usize,
}
impl Reader<'_> {
    fn bytes(&mut self, length: usize) -> Result<&[u8], String> {
        let end = self
            .offset
            .checked_add(length)
            .filter(|end| *end <= self.data.len())
            .ok_or("truncated scene packet")?;
        let out = &self.data[self.offset..end];
        self.offset = end;
        Ok(out)
    }
    fn u32(&mut self) -> Result<u32, String> {
        Ok(u32::from_le_bytes(self.bytes(4)?.try_into().unwrap()))
    }
    fn u64(&mut self) -> Result<u64, String> {
        Ok(u64::from_le_bytes(self.bytes(8)?.try_into().unwrap()))
    }
    fn floats<const N: usize>(&mut self) -> Result<[f32; N], String> {
        let mut out = [0.; N];
        for value in &mut out {
            *value = f32::from_bits(self.u32()?);
            if !value.is_finite() {
                return Err("scene contains a nonfinite float".into());
            }
        }
        Ok(out)
    }
}
impl ScenePacket {
    pub fn decode(data: &[u8]) -> Result<Self, String> {
        if data.len() > 66 * 1024 * 1024 {
            return Err("scene packet exceeds byte budget".into());
        }
        let mut r = Reader { data, offset: 0 };
        if r.u32()? != 2 {
            return Err("unsupported scene packet".into());
        }
        let opcode = r.u32()?;
        if opcode != 10 && opcode != 11 {
            return Err("unsupported scene packet".into());
        }
        let textured = opcode == 11;
        let revision = r.u64()?;
        if r.u64()? != (data.len() - r.offset) as u64 {
            return Err("scene body length mismatch".into());
        }
        let view = r.u64()?;
        let base = r.u64()?;
        if view == 0 || revision == 0 || base >= revision {
            return Err("invalid scene view or revision".into());
        }
        let retained_count = r.u32()? as usize;
        let geometry_count = r.u32()? as usize;
        let mesh_count = r.u32()? as usize;
        let update_count = r.u32()? as usize;
        if [retained_count, geometry_count, mesh_count, update_count]
            .iter()
            .any(|n| *n > MAX_MESHES)
            || (base == 0 && update_count != mesh_count)
            || update_count > mesh_count
        {
            return Err("scene table count exceeds its limit".into());
        }
        let view_projection = r.floats()?;
        let background = r.floats::<3>()?.map(f64::from);
        let light_direction = r.floats()?;
        let ambient = r.floats::<1>()?[0];
        let owned_texture_count = if textured { r.u32()? as usize } else { 0 };
        let texture_count = if textured { r.u32()? as usize } else { 0 };
        if owned_texture_count > MAX_MESHES || texture_count > MAX_MESHES {
            return Err("texture table count exceeds limit".into());
        }
        let mut retained = HashSet::new();
        for _ in 0..retained_count {
            if !retained.insert(r.u32()?) {
                return Err("duplicate retained geometry".into());
            }
        }
        let mut retained_textures = HashSet::new();
        for _ in 0..owned_texture_count {
            if !retained_textures.insert(r.u32()?) {
                return Err("duplicate owned texture".into());
            }
        }
        let mut textures = Vec::new();
        let mut texture_bytes = 0_usize;
        for _ in 0..texture_count {
            let id = r.u32()?;
            let width = r.u32()?;
            let height = r.u32()?;
            let format = r.u32()?;
            let mips = r.u32()?;
            if width == 0
                || height == 0
                || width > 4096
                || height > 4096
                || format > 1
                || mips == 0
                || mips > 32 - width.max(height).leading_zeros()
            {
                return Err("invalid texture descriptor".into());
            }
            let mut levels = Vec::new();
            for mip in 0..mips {
                let length = r.u32()? as usize;
                let expected = (width >> mip).max(1) as usize * (height >> mip).max(1) as usize * 4;
                if length != expected {
                    return Err("texture mip length mismatch".into());
                }
                texture_bytes += length;
                if texture_bytes > 64 * 1024 * 1024 {
                    return Err("texture upload budget exceeded".into());
                }
                levels.push(r.bytes(length)?.to_vec());
            }
            textures.push(SceneTexture {
                id,
                width,
                height,
                format,
                levels,
            });
        }
        let mut geometries = Vec::new();
        let mut vertices = 0;
        let mut indices = 0;
        for _ in 0..geometry_count {
            let id = r.u32()?;
            let vertex_count = r.u32()? as usize;
            let index_count = r.u32()? as usize;
            let uv_flags = if textured { r.u32()? } else { 0 };
            if uv_flags > 3 {
                return Err("unknown UV attributes".into());
            }
            if vertex_count > MAX_VERTICES || index_count > MAX_INDICES {
                return Err("geometry table exceeds budget".into());
            }
            vertices += vertex_count;
            indices += index_count;
            if vertices > MAX_VERTICES || indices > MAX_INDICES {
                return Err("geometry upload exceeds budget".into());
            }
            let needed = vertex_count * (24 + uv_flags.count_ones() as usize * 8) + index_count * 4;
            if needed > data.len() - r.offset {
                return Err("truncated geometry payload".into());
            }
            let mut geometry = Geometry {
                id,
                positions: Vec::with_capacity(vertex_count),
                normals: Vec::with_capacity(vertex_count),
                indices: Vec::with_capacity(index_count),
                uv0: Vec::new(),
                uv1: Vec::new(),
            };
            for _ in 0..vertex_count {
                geometry.positions.push(r.floats()?);
            }
            for _ in 0..vertex_count {
                geometry.normals.push(r.floats()?);
            }
            for _ in 0..index_count {
                geometry.indices.push(r.u32()?);
            }
            if uv_flags & 1 != 0 {
                for _ in 0..vertex_count {
                    geometry.uv0.push(r.floats()?);
                }
            }
            if uv_flags & 2 != 0 {
                for _ in 0..vertex_count {
                    geometry.uv1.push(r.floats()?);
                }
            }
            geometry.validate()?;
            geometries.push(geometry);
        }
        let mut updates = Vec::new();
        let mut changed = HashSet::new();
        for _ in 0..update_count {
            let index = r.u32()? as usize;
            if index >= mesh_count || !changed.insert(index) {
                return Err("invalid or repeated mesh index".into());
            }
            let geometry = r.u32()?;
            let model = r.floats()?;
            let color = r.floats()?;
            let unlit = r.u32()?;
            if unlit > 1 {
                return Err("invalid material flag".into());
            }
            let map_flag = if textured { r.u32()? } else { 0 };
            if map_flag > 1 {
                return Err("invalid color map flag".into());
            }
            let color_map = if map_flag == 1 {
                let texture = r.u32()?;
                let uv_set = r.u32()?;
                let mut sampler = [0; 5];
                for entry in &mut sampler {
                    *entry = r.u32()?;
                }
                let map = ColorMap {
                    texture,
                    uv_set,
                    sampler,
                };
                map.validate()?;
                Some(map)
            } else {
                None
            };
            updates.push((
                index,
                Mesh {
                    geometry,
                    model,
                    color,
                    unlit: unlit == 1,
                    color_map,
                },
            ));
        }
        if r.offset != data.len() {
            return Err("trailing scene bytes".into());
        }
        Ok(Self {
            view,
            revision,
            base,
            retained,
            geometries,
            mesh_count,
            updates,
            view_projection,
            background,
            light_direction,
            ambient,
            retained_textures,
            textures,
        })
    }
    pub fn view(&self) -> u64 {
        self.view
    }
    pub fn resolve(self, previous: Option<&ViewState>) -> Result<Frame, String> {
        if previous.is_some_and(|p| self.revision <= p.revision) {
            return Err("stale scene revision".into());
        }
        let mut meshes = if self.base == 0 {
            vec![
                Mesh {
                    geometry: 0,
                    model: [0.; 16],
                    color: [0.; 3],
                    unlit: false,
                    color_map: None
                };
                self.mesh_count
            ]
        } else {
            let old = previous
                .filter(|p| p.revision == self.base && p.meshes.len() == self.mesh_count)
                .ok_or("scene baseline no longer matches")?;
            old.meshes.clone()
        };
        for (index, mesh) in self.updates {
            meshes[index] = mesh;
        }
        if meshes
            .iter()
            .any(|mesh| !self.retained.contains(&mesh.geometry))
        {
            return Err("visible geometry must be retained by its view".into());
        }
        if meshes.iter().any(|m| {
            m.color_map
                .as_ref()
                .is_some_and(|map| !self.retained_textures.contains(&map.texture))
        }) {
            return Err("visible textures must be owned by the view".into());
        }
        let binary = Some(ViewState {
            view: self.view,
            revision: self.revision,
            retained: self.retained,
            meshes: meshes.clone(),
            retained_textures: self.retained_textures,
        });
        Ok(Frame {
            version: 1,
            view_projection: self.view_projection,
            background: self.background,
            light_direction: self.light_direction,
            ambient: self.ambient,
            geometries: self.geometries,
            meshes,
            binary,
            textures: self.textures,
        })
    }
}
