use crate::scene::{
    AttributeRange, ColorMap, Frame, Geometry, GeometryPatch, IndexFormat, MAX_INDICES, MAX_MESHES,
    MAX_VERTICES, Mesh, SceneTexture,
};
use std::collections::HashSet;

#[derive(Clone, PartialEq)]
pub struct ViewState {
    pub view: u64,
    pub revision: u64,
    pub retained: HashSet<u32>,
    pub meshes: Vec<Mesh>,
    pub retained_textures: HashSet<u32>,
    pub retained_instances: HashSet<u32>,
    pub retained_poses: HashSet<u32>,
}
pub struct ScenePacket {
    shadows: crate::shadows::ShadowFrame,
    view: u64,
    revision: u64,
    base: u64,
    retained: HashSet<u32>,
    geometries: Vec<Geometry>,
    mesh_count: usize,
    updates: Vec<(usize, Mesh)>,
    view_projection: [f32; 16],
    background: [f64; 3],
    background_alpha: f32,
    color_pipeline: Option<crate::scene::ColorPipeline>,
    light_direction: [f32; 3],
    ambient: f32,
    lights: Vec<crate::lighting::PunctualLight>,
    hemispheres: Vec<crate::lighting::HemisphereLight>,
    areas: Vec<crate::lighting::RectAreaLight>,
    retained_textures: HashSet<u32>,
    textures: Vec<SceneTexture>,
    geometry_patches: Vec<GeometryPatch>,
    retained_instances: HashSet<u32>,
    retained_poses: HashSet<u32>,
    poses: Vec<crate::deformation::Pose>,
    instances: Vec<crate::instances::Instances>,
    instance_patches: Vec<crate::instances::InstancePatch>,
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
        if !(10..=30).contains(&opcode) {
            return Err("unsupported scene packet".into());
        }
        let textured = opcode >= 11;
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
        let background_alpha = if opcode >= 18 {
            r.floats::<1>()?[0]
        } else {
            1.
        };
        if !(0.0..=1.0).contains(&background_alpha) {
            return Err("invalid background alpha".into());
        }
        let mut lights = Vec::new();
        if opcode >= 19 {
            let count = r.u32()? as usize;
            if count > crate::lighting::MAX_LIGHTS {
                return Err("scene exceeds punctual light limit".into());
            }
            for _ in 0..count {
                let light = crate::lighting::PunctualLight {
                    kind: r.u32()?,
                    color: r.floats()?,
                    intensity: r.floats::<1>()?[0],
                    position: r.floats()?,
                    direction: r.floats()?,
                    range: r.floats::<1>()?[0],
                    inner_cos: r.floats::<1>()?[0],
                    outer_cos: r.floats::<1>()?[0],
                };
                light.validate()?;
                lights.push(light);
            }
        }
        let mut hemispheres = Vec::new();
        if opcode >= 20 {
            let count = r.u32()? as usize;
            if count > crate::lighting::MAX_HEMISPHERES {
                return Err("scene exceeds hemisphere light limit".into());
            }
            for _ in 0..count {
                let light = crate::lighting::HemisphereLight {
                    sky_color: r.floats()?,
                    ground_color: r.floats()?,
                    direction: r.floats()?,
                    intensity: r.floats::<1>()?[0],
                };
                light.validate()?;
                hemispheres.push(light);
            }
        }
        let mut areas = Vec::new();
        if opcode >= 30 {
            let count = r.u32()? as usize;
            if count > crate::lighting::MAX_AREAS {
                return Err("scene exceeds area light limit".into());
            }
            for _ in 0..count {
                let light = crate::lighting::RectAreaLight {
                    position: r.floats()?,
                    half_width: r.floats()?,
                    half_height: r.floats()?,
                    color: r.floats()?,
                    intensity: r.floats::<1>()?[0],
                };
                light.validate()?;
                areas.push(light);
            }
        }
        let has_color_pipeline = if opcode >= 22 {
            match r.u32()? {
                0 => false,
                1 => true,
                _ => return Err("Invalid HDR presence flag".into()),
            }
        } else {
            opcode >= 21
        };
        let color_pipeline = if has_color_pipeline {
            let pipeline = crate::scene::ColorPipeline {
                tone_mapping: r.u32()?,
                exposure: r.floats::<1>()?[0],
                sample_count: if opcode >= 28 { r.u32()? } else { 1 },
            };
            pipeline.validate()?;
            Some(pipeline)
        } else {
            None
        };
        let mut shadows = crate::shadows::ShadowFrame::default();
        if opcode >= 22 {
            let count = r.u32()? as usize;
            if count > crate::shadows::MAX_VIEWS {
                return Err("Excessive shadow view count".into());
            }
            shadows.forward = r.floats()?;
            for _ in 0..count {
                let light_index = r.u32()?;
                let kind = r.u32()?;
                let resolution = r.u32()?;
                let revision = r.u32()?;
                let view_projection = r.floats()?;
                let values = r.floats::<8>()?;
                shadows.views.push(crate::shadows::ShadowView {
                    light_index,
                    kind,
                    resolution,
                    revision,
                    view_projection,
                    near: values[0],
                    far: values[1],
                    blend: values[2],
                    strength: values[3],
                    bias: values[4],
                    normal_bias: values[5],
                    slope_bias: values[6],
                    filter_radius: values[7],
                });
            }
            shadows.validate(&lights)?;
        }
        let owned_texture_count = if textured { r.u32()? as usize } else { 0 };
        let texture_count = if textured { r.u32()? as usize } else { 0 };
        if owned_texture_count > MAX_MESHES || texture_count > MAX_MESHES {
            return Err("texture table count exceeds limit".into());
        }
        let patch_count = if opcode >= 12 { r.u32()? as usize } else { 0 };
        if patch_count > MAX_MESHES {
            return Err("geometry patch count exceeds limit".into());
        }
        let instance_counts = if opcode >= 24 {
            [r.u32()? as usize, r.u32()? as usize, r.u32()? as usize]
        } else {
            [0; 3]
        };
        if instance_counts.iter().any(|n| *n > MAX_MESHES) {
            return Err("instance table count exceeds limit".into());
        }
        let pose_counts = if opcode >= 25 {
            [r.u32()? as usize, r.u32()? as usize]
        } else {
            [0; 2]
        };
        if pose_counts.iter().any(|n| *n > MAX_MESHES) {
            return Err("pose table exceeds limit".into());
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
        let mut retained_instances = HashSet::new();
        for _ in 0..instance_counts[0] {
            let id = r.u32()?;
            if id == 0 || !retained_instances.insert(id) {
                return Err("invalid retained instance identifier".into());
            }
        }
        let mut retained_poses = HashSet::new();
        for _ in 0..pose_counts[0] {
            let id = r.u32()?;
            if id == 0 || !retained_poses.insert(id) {
                return Err("invalid retained pose identifier".into());
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
            let mip_generation = if opcode >= 14 { r.u32()? } else { 0 };
            if width == 0
                || height == 0
                || width > 4096
                || height > 4096
                || format > 1
                || mip_generation > 2
                || (mip_generation != 0 && mips != 1)
                || mips == 0
                || mips > 32 - width.max(height).leading_zeros()
            {
                return Err("invalid texture descriptor".into());
            }
            let target_mips = if mip_generation == 0 {
                mips
            } else {
                32 - width.max(height).leading_zeros()
            };
            texture_bytes += (0..target_mips)
                .map(|m| (width >> m).max(1) as usize * (height >> m).max(1) as usize * 4)
                .sum::<usize>();
            if texture_bytes > 64 * 1024 * 1024 {
                return Err("texture residency budget exceeded".into());
            }
            let mut levels = Vec::new();
            for mip in 0..mips {
                let length = r.u32()? as usize;
                let expected = (width >> mip).max(1) as usize * (height >> mip).max(1) as usize * 4;
                if length != expected {
                    return Err("texture mip length mismatch".into());
                }
                levels.push(r.bytes(length)?.to_vec());
            }
            textures.push(SceneTexture {
                id,
                width,
                height,
                format,
                levels,
                mip_generation,
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
            let topology = if opcode >= 16 { r.u32()? } else { 0 };
            if topology > 3 {
                return Err("unsupported geometry topology".into());
            }
            let index_format = if opcode >= 13 && uv_flags & 4 != 0 {
                IndexFormat::Uint16
            } else {
                IndexFormat::Uint32
            };
            if uv_flags
                > if opcode >= 25 {
                    127
                } else if opcode >= 23 {
                    31
                } else if opcode >= 20 {
                    15
                } else if opcode >= 13 {
                    7
                } else {
                    3
                }
            {
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
            let needed = vertex_count
                * (24
                    + (uv_flags & 3).count_ones() as usize * 8
                    + if uv_flags & 8 != 0 { 16 } else { 0 }
                    + if uv_flags & 16 != 0 { 16 } else { 0 }
                    + if uv_flags & 32 != 0 { 32 } else { 0 })
                + index_count * index_format.bytes();
            if needed > data.len() - r.offset {
                return Err("truncated geometry payload".into());
            }
            let mut geometry = Geometry {
                id,
                topology,
                positions: Vec::with_capacity(vertex_count),
                normals: Vec::with_capacity(vertex_count),
                indices: Vec::with_capacity(index_count),
                index_format,
                uv0: Vec::new(),
                uv1: Vec::new(),
                tangents: Vec::new(),
                colors: Vec::new(),
                joints: Vec::new(),
                weights: Vec::new(),
                morphs: Vec::new(),
            };
            for _ in 0..vertex_count {
                geometry.positions.push(r.floats()?);
            }
            for _ in 0..vertex_count {
                geometry.normals.push(r.floats()?);
            }
            for _ in 0..index_count {
                geometry.indices.push(match index_format {
                    IndexFormat::Uint16 => {
                        u16::from_le_bytes(r.bytes(2)?.try_into().unwrap()) as u32
                    }
                    IndexFormat::Uint32 => r.u32()?,
                });
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
            if uv_flags & 8 != 0 {
                for _ in 0..vertex_count {
                    geometry.tangents.push(r.floats()?);
                }
            }
            if uv_flags & 16 != 0 {
                for _ in 0..vertex_count {
                    geometry.colors.push(r.floats()?);
                }
            }
            if uv_flags & 32 != 0 {
                for _ in 0..vertex_count {
                    geometry
                        .joints
                        .push([r.u32()?, r.u32()?, r.u32()?, r.u32()?]);
                }
                for _ in 0..vertex_count {
                    geometry.weights.push(r.floats()?);
                }
            }
            if uv_flags & 64 != 0 {
                let count = r.u32()? as usize;
                if count == 0
                    || count > crate::deformation::MAX_MORPHS
                    || count * vertex_count * 36 > 64 * 1024 * 1024
                {
                    return Err("morph table exceeds budget".into());
                }
                for _ in 0..count {
                    let flags = r.u32()?;
                    if flags == 0
                        || flags > 7
                        || flags.count_ones() as usize * vertex_count * 12 > data.len() - r.offset
                    {
                        return Err("invalid or truncated morph attributes".into());
                    }
                    let mut target = crate::deformation::MorphTarget::default();
                    for (flag, stream) in [
                        (1, &mut target.positions),
                        (2, &mut target.normals),
                        (4, &mut target.tangents),
                    ] {
                        if flags & flag != 0 {
                            for _ in 0..vertex_count {
                                stream.push(r.floats()?);
                            }
                        }
                    }
                    geometry.morphs.push(target);
                }
            }
            geometry.validate()?;
            geometries.push(geometry);
        }
        let mut geometry_patches = Vec::new();
        let mut patch_ids = HashSet::new();
        for _ in 0..patch_count {
            let id = r.u32()?;
            let base = r.u32()?;
            let count = r.u32()? as usize;
            if id == base || count == 0 || count > 64 || !patch_ids.insert(id) {
                return Err("invalid geometry patch descriptor".into());
            }
            let mut ranges = Vec::new();
            for _ in 0..count {
                let semantic = r.u32()?;
                let first = r.u32()?;
                let count = r.u32()?;
                if semantic
                    > if opcode >= 25 {
                        127
                    } else if opcode >= 23 {
                        5
                    } else if opcode >= 20 {
                        4
                    } else {
                        3
                    }
                    || count == 0
                    || first
                        .checked_add(count)
                        .is_none_or(|end| end as usize > MAX_VERTICES)
                {
                    return Err("invalid geometry patch range".into());
                }
                let values_count = count as usize
                    * if semantic < 2 {
                        3
                    } else if semantic < 4 {
                        2
                    } else {
                        4
                    };
                if values_count * 4 > data.len() - r.offset {
                    return Err("truncated geometry patch".into());
                }
                let mut values = Vec::with_capacity(values_count);
                for _ in 0..values_count {
                    values.push(r.floats::<1>()?[0]);
                }
                ranges.push(AttributeRange {
                    semantic,
                    first,
                    values,
                });
            }
            geometry_patches.push(GeometryPatch { id, base, ranges });
        }
        if geometry_patches.iter().any(|p| patch_ids.contains(&p.base))
            || geometries.iter().any(|g| patch_ids.contains(&g.id))
        {
            return Err("geometry patch chains or repeated targets are unsupported".into());
        }
        let mut instances = Vec::new();
        let mut instance_patches = Vec::new();
        let mut instance_ids = HashSet::new();
        let mut slots = 0_usize;
        let instance_bytes = if opcode >= 26 { 76 } else { 64 };
        for _ in 0..instance_counts[1] {
            let id = r.u32()?;
            let count = r.u32()? as usize;
            slots = slots
                .checked_add(count)
                .ok_or("instance slot count overflow")?;
            if id == 0
                || count == 0
                || slots > crate::instances::MAX_INSTANCES
                || !instance_ids.insert(id)
                || count * instance_bytes > data.len() - r.offset
            {
                return Err("invalid instance upload or capacity".into());
            }
            let mut transforms = Vec::with_capacity(count);
            let mut colors = Vec::with_capacity(count);
            for _ in 0..count {
                transforms.push(r.floats()?);
                colors.push(if opcode >= 26 { r.floats()? } else { [1.; 3] });
            }
            let value = crate::instances::Instances {
                id,
                transforms,
                colors,
            };
            value.validate()?;
            instances.push(value);
        }
        for _ in 0..instance_counts[2] {
            let id = r.u32()?;
            let base = r.u32()?;
            let count = r.u32()? as usize;
            if id == 0
                || base == 0
                || id == base
                || count == 0
                || count > 64
                || !instance_ids.insert(id)
            {
                return Err("invalid instance patch descriptor".into());
            }
            let mut ranges = Vec::new();
            let mut previous_end = 0;
            for _ in 0..count {
                let first = r.u32()? as usize;
                let length = r.u32()? as usize;
                slots = slots
                    .checked_add(length)
                    .ok_or("instance slot count overflow")?;
                if length == 0
                    || slots > crate::instances::MAX_INSTANCES
                    || first < previous_end
                    || first
                        .checked_add(length)
                        .is_none_or(|end| end > crate::instances::MAX_INSTANCES)
                    || length * instance_bytes > data.len() - r.offset
                {
                    return Err("invalid instance patch range".into());
                }
                let mut transforms = Vec::with_capacity(length);
                let mut colors = Vec::with_capacity(length);
                for _ in 0..length {
                    transforms.push(r.floats()?);
                    let color = if opcode >= 26 { r.floats()? } else { [1.; 3] };
                    if color.iter().any(|v| !(0.0..=1.0).contains(v)) {
                        return Err("invalid instance color".into());
                    }
                    colors.push(color);
                }
                previous_end = first + length;
                ranges.push(crate::instances::InstanceRange {
                    first,
                    transforms,
                    colors,
                });
            }
            instance_patches.push(crate::instances::InstancePatch { id, base, ranges });
        }
        if instance_patches
            .iter()
            .any(|p| instance_ids.contains(&p.base))
        {
            return Err("instance patch chains are unsupported".into());
        }
        let mut updates = Vec::new();
        let mut poses = Vec::new();
        for _ in 0..pose_counts[1] {
            let id = r.u32()?;
            let geometry = r.u32()?;
            let morphs = r.u32()? as usize;
            let joints = r.u32()? as usize;
            if id == 0
                || morphs > crate::deformation::MAX_MORPHS
                || joints > crate::deformation::MAX_JOINTS
            {
                return Err("pose descriptor exceeds limits".into());
            }
            let mut weights = Vec::new();
            let mut matrices = Vec::new();
            for _ in 0..morphs {
                weights.push(r.floats::<1>()?[0]);
            }
            for _ in 0..joints {
                matrices.push(r.floats()?);
            }
            poses.push(crate::deformation::Pose {
                id,
                geometry,
                weights,
                matrices,
            });
        }
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
            let mut mesh = Mesh {
                geometry,
                model,
                color,
                unlit: unlit == 1,
                color_map,
                ..Default::default()
            };
            if opcode >= 15 {
                mesh.alpha_mode = r.u32()?;
                mesh.opacity = r.floats::<1>()?[0];
                mesh.alpha_cutoff = r.floats::<1>()?[0];
                let depth_test = r.u32()?;
                let depth_write = r.u32()?;
                if depth_test > 1 || depth_write > 1 {
                    return Err("invalid depth flags".into());
                }
                mesh.depth_test = depth_test == 1;
                mesh.depth_write = Some(depth_write == 1);
                mesh.render_order = r.u32()? as i32;
                if opcode >= 16 {
                    mesh.primitive_kind = r.u32()?;
                    mesh.primitive_size = r.floats::<1>()?[0];
                    mesh.size_units = r.u32()?;
                    mesh.point_shape = r.u32()?;
                    if opcode >= 17 {
                        mesh.side = r.u32()?;
                    }
                }
                if opcode >= 19 {
                    match r.u32()? {
                        0 => (),
                        1 => {
                            let mut pbr = crate::lighting::StandardMaterial {
                                physical: None,
                                metallic: r.floats::<1>()?[0],
                                roughness: r.floats::<1>()?[0],
                                emissive: r.floats()?,
                                normal_scale: 1.,
                                occlusion_strength: 1.,
                                normal_map: None,
                                metallic_roughness_map: None,
                                occlusion_map: None,
                                emissive_map: None,
                            };
                            if opcode >= 20 {
                                pbr.normal_scale = r.floats::<1>()?[0];
                                pbr.occlusion_strength = r.floats::<1>()?[0];
                                for map in [
                                    &mut pbr.normal_map,
                                    &mut pbr.metallic_roughness_map,
                                    &mut pbr.occlusion_map,
                                    &mut pbr.emissive_map,
                                ] {
                                    match r.u32()? {
                                        0 => (),
                                        1 => {
                                            let texture = r.u32()?;
                                            let uv_set = r.u32()?;
                                            let mut sampler = [0; 5];
                                            for value in &mut sampler {
                                                *value = r.u32()?;
                                            }
                                            *map = Some(ColorMap {
                                                texture,
                                                uv_set,
                                                sampler,
                                            });
                                        }
                                        _ => return Err("invalid standard texture flag".into()),
                                    }
                                }
                            }
                            mesh.pbr = Some(pbr);
                        }
                        _ => return Err("invalid standard material flag".into()),
                    }
                }
                if opcode >= 29 {
                    match r.u32()? {
                        0 => (),
                        1 => {
                            mesh.pbr
                                .as_mut()
                                .ok_or("physical material requires PBR")?
                                .physical = Some(r.floats()?);
                        }
                        _ => return Err("invalid physical material flag".into()),
                    }
                }
                mesh.validate_material()?;
            }
            if opcode >= 22 {
                let cast = r.u32()?;
                let receive = r.u32()?;
                if cast > 1 || receive > 1 {
                    return Err("Invalid shadow mesh flags".into());
                }
                mesh.cast_shadow = cast == 1;
                mesh.receive_shadow = receive == 1;
            }
            if opcode >= 23 {
                mesh.vertex_colors = match r.u32()? {
                    0 => false,
                    1 => true,
                    _ => return Err("Invalid vertex color flag".into()),
                };
            }
            if opcode >= 24 {
                mesh.instances = r.u32()?;
                mesh.instance_count = r.u32()?;
                mesh.validate_material()?;
            }
            if opcode >= 25 {
                mesh.pose = r.u32()?;
                mesh.validate_material()?;
            }
            if opcode >= 27 {
                mesh.color_visible = match r.u32()? {
                    0 => false,
                    1 => true,
                    _ => return Err("Invalid color visibility flag".into()),
                };
            }
            updates.push((index, mesh));
        }
        if r.offset != data.len() {
            return Err("trailing scene bytes".into());
        }
        Ok(Self {
            shadows,
            view,
            revision,
            base,
            retained,
            geometries,
            mesh_count,
            updates,
            view_projection,
            background,
            background_alpha,
            color_pipeline,
            light_direction,
            ambient,
            lights,
            hemispheres,
            areas,
            retained_textures,
            textures,
            geometry_patches,
            retained_instances,
            retained_poses,
            poses,
            instances,
            instance_patches,
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
            vec![Mesh::default(); self.mesh_count]
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
            m.texture_maps()
                .any(|map| !self.retained_textures.contains(&map.texture))
        }) {
            return Err("visible textures must be owned by the view".into());
        }
        if meshes
            .iter()
            .any(|m| m.instances != 0 && !self.retained_instances.contains(&m.instances))
            || self
                .instances
                .iter()
                .any(|i| !meshes.iter().any(|m| m.instances == i.id))
            || self
                .instance_patches
                .iter()
                .any(|i| !meshes.iter().any(|m| m.instances == i.id))
        {
            return Err("visible instance resources must be owned and uploads referenced".into());
        }
        if meshes
            .iter()
            .any(|m| m.pose != 0 && !self.retained_poses.contains(&m.pose))
            || self
                .poses
                .iter()
                .any(|p| !meshes.iter().any(|m| m.pose == p.id))
        {
            return Err("visible poses must be owned and uploads referenced".into());
        }
        let binary = Some(ViewState {
            view: self.view,
            revision: self.revision,
            retained: self.retained,
            meshes: meshes.clone(),
            retained_textures: self.retained_textures,
            retained_instances: self.retained_instances,
            retained_poses: self.retained_poses,
        });
        Ok(Frame {
            environment: None,
            shadows: self.shadows,
            version: 1,
            view_projection: self.view_projection,
            background: self.background,
            background_alpha: self.background_alpha,
            color_pipeline: self.color_pipeline,
            light_direction: self.light_direction,
            ambient: self.ambient,
            lights: self.lights,
            hemispheres: self.hemispheres,
            areas: self.areas,
            geometries: self.geometries,
            meshes,
            binary,
            textures: self.textures,
            geometry_patches: self.geometry_patches,
            instances: self.instances,
            poses: self.poses,
            instance_patches: self.instance_patches,
            graph: None,
        })
    }
}
