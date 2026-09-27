use crate::scene::{Frame, Geometry, MAX_INDICES, MAX_MESHES, MAX_VERTICES, Mesh};
use std::collections::HashSet;

#[derive(Clone, PartialEq)]
pub struct ViewState {
    pub view: u64,
    pub revision: u64,
    pub retained: HashSet<u32>,
    pub meshes: Vec<Mesh>,
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
        if r.u32()? != 2 || r.u32()? != 10 {
            return Err("unsupported scene packet".into());
        }
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
        let mut retained = HashSet::new();
        for _ in 0..retained_count {
            if !retained.insert(r.u32()?) {
                return Err("duplicate retained geometry".into());
            }
        }
        let mut geometries = Vec::new();
        let mut vertices = 0;
        let mut indices = 0;
        for _ in 0..geometry_count {
            let id = r.u32()?;
            let vertex_count = r.u32()? as usize;
            let index_count = r.u32()? as usize;
            if vertex_count > MAX_VERTICES || index_count > MAX_INDICES {
                return Err("geometry table exceeds budget".into());
            }
            vertices += vertex_count;
            indices += index_count;
            if vertices > MAX_VERTICES || indices > MAX_INDICES {
                return Err("geometry upload exceeds budget".into());
            }
            let needed = vertex_count * 24 + index_count * 4;
            if needed > data.len() - r.offset {
                return Err("truncated geometry payload".into());
            }
            let mut geometry = Geometry {
                id,
                positions: Vec::with_capacity(vertex_count),
                normals: Vec::with_capacity(vertex_count),
                indices: Vec::with_capacity(index_count),
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
            updates.push((
                index,
                Mesh {
                    geometry,
                    model,
                    color,
                    unlit: unlit == 1,
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
                    unlit: false
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
        let binary = Some(ViewState {
            view: self.view,
            revision: self.revision,
            retained: self.retained,
            meshes: meshes.clone(),
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
        })
    }
}
