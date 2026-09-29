use draco_core::{
    DataType, DecodeLimits, DecoderBuffer, ErrorKind, GeometryMetadata, Mesh, MeshDecoder,
    PointIndex,
};
use std::sync::atomic::{AtomicUsize, Ordering};

#[repr(C)]
#[derive(Clone, Copy)]
pub struct MeshLimits {
    pub version: u32,
    pub max_vertices: u32,
    pub max_triangles: u32,
    pub max_attributes: u32,
    pub max_encoded_bytes: u64,
    pub max_decoded_bytes: u64,
}
impl MeshLimits {
    fn validate(&self) -> Result<(), u32> {
        if self.version != 1
            || !(1..=1_000_000).contains(&self.max_vertices)
            || !(1..=1_000_000).contains(&self.max_triangles)
            || !(1..=32).contains(&self.max_attributes)
            || !(1..=16 * 1024 * 1024).contains(&self.max_encoded_bytes)
            || !(1..=64 * 1024 * 1024).contains(&self.max_decoded_bytes)
        {
            return Err(1);
        }
        Ok(())
    }
    fn counts(&self, vertices: u64, faces: u64) -> Result<(), u32> {
        if vertices == 0 || faces == 0 {
            return Err(1);
        }
        if vertices > self.max_vertices as u64
            || faces > self.max_triangles as u64
            || faces > self.max_decoded_bytes / 12
        {
            return Err(2);
        }
        Ok(())
    }
}

fn failure(error: draco_core::DracoError) -> u32 {
    match error.kind() {
        ErrorKind::LimitExceeded | ErrorKind::AllocationExceedsInput => 2,
        ErrorKind::UnsupportedVersion
        | ErrorKind::UnsupportedFeature
        | ErrorKind::BitstreamVersionUnsupported => 3,
        _ => 1,
    }
}

/// Checks count fields before the decoder's connectivity workspace is allocated.
fn preflight(input: &[u8], limits: &MeshLimits) -> Result<(), u32> {
    if input.len() < 11 || &input[..5] != b"DRACO" {
        return Err(1);
    }
    if input[5..8] != [2, 2, 1] {
        return Err(3);
    }
    let method = input[8];
    if method > 1 {
        return Err(3);
    }
    let flags = u16::from_le_bytes([input[9], input[10]]);
    if flags & !0x8000 != 0 {
        return Err(3);
    }
    let mut buffer = DecoderBuffer::new(&input[11..]);
    buffer.set_version(2, 2);
    if flags & 0x8000 != 0 {
        GeometryMetadata::decode(&mut buffer).map_err(failure)?;
    }
    let (vertices, faces) = if method == 0 {
        let faces = buffer.decode_varint().map_err(failure)?;
        let vertices = buffer.decode_varint().map_err(failure)?;
        (vertices, faces)
    } else {
        if buffer.decode_u8().map_err(failure)? > 2 {
            return Err(3);
        }
        let vertices = buffer.decode_varint().map_err(failure)?;
        let faces = buffer.decode_varint().map_err(failure)?;
        if buffer.decode_u8().map_err(failure)? as u32 > limits.max_attributes {
            return Err(2);
        }
        (vertices, faces)
    };
    limits.counts(vertices, faces)
}

static ACTIVE: AtomicUsize = AtomicUsize::new(0);
struct Admission;
impl Drop for Admission {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::AcqRel);
    }
}

/// Returns a little-endian packet: counts, triangle indices, then attribute
/// headers (unique ID, scalar type, components, normalized, byte length) and data.
/// Errors: 1 invalid, 2 limits, 3 unsupported, 4 busy, 5 internal failure.
pub fn decode_draco(input: &[u8], limits: &MeshLimits) -> Result<Vec<u8>, u32> {
    limits.validate()?;
    if input.len() as u64 > limits.max_encoded_bytes {
        return Err(2);
    }
    if ACTIVE
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n < 2).then_some(n + 1)
        })
        .is_err()
    {
        return Err(4);
    }
    let _admission = Admission;
    std::panic::catch_unwind(|| decode_inner(input, limits)).unwrap_or(Err(5))
}

fn decode_inner(input: &[u8], limits: &MeshLimits) -> Result<Vec<u8>, u32> {
    preflight(input, limits)?;
    let policy = DecodeLimits::default()
        .with_max_points(limits.max_vertices as u64)
        .with_max_faces(limits.max_triangles as u64)
        .with_max_decoded_bytes(limits.max_decoded_bytes);
    let mut buffer = DecoderBuffer::new(input).with_limits(policy);
    let mut mesh = Mesh::new();
    MeshDecoder::new()
        .decode(&mut buffer, &mut mesh)
        .map_err(failure)?;
    limits.counts(mesh.num_points() as u64, mesh.num_faces() as u64)?;
    if mesh.num_attributes() < 1 {
        return Err(1);
    }
    if mesh.num_attributes() as u32 > limits.max_attributes {
        return Err(2);
    }
    let mut payload = mesh.num_faces() * 12;
    let mut descriptors = Vec::new();
    let mut ids = std::collections::HashSet::new();
    for i in 0..mesh.num_attributes() {
        let attribute = mesh.attribute(i);
        let ty = match attribute.data_type() {
            DataType::Int8 => 0,
            DataType::Uint8 => 1,
            DataType::Int16 => 2,
            DataType::Uint16 => 3,
            DataType::Uint32 => 4,
            DataType::Float32 => 5,
            _ => return Err(3),
        };
        let components = attribute.num_components() as usize;
        if !(1..=4).contains(&components) || !ids.insert(attribute.unique_id()) {
            return Err(1);
        }
        if attribute.normalized() && ty >= 4 {
            return Err(1);
        }
        let stride = components * attribute.data_type().byte_length();
        if attribute.byte_stride() != stride as i64 {
            return Err(1);
        }
        let length = mesh.num_points() * stride;
        payload = payload.checked_add(length).ok_or(2u32)?;
        if payload as u64 > limits.max_decoded_bytes {
            return Err(2);
        }
        descriptors.push((attribute, ty, stride, length));
    }
    let length = 12 + descriptors.len() * 20 + payload;
    let mut output = Vec::new();
    output.try_reserve_exact(length).map_err(|_| 2u32)?;
    for n in [
        mesh.num_points() as u32,
        (mesh.num_faces() * 3) as u32,
        descriptors.len() as u32,
    ] {
        output.extend_from_slice(&n.to_le_bytes());
    }
    for face in mesh.faces() {
        for index in face {
            if index.0 as usize >= mesh.num_points() {
                return Err(1);
            }
            output.extend_from_slice(&index.0.to_le_bytes());
        }
    }
    for (attribute, ty, stride, length) in descriptors {
        for n in [
            attribute.unique_id(),
            ty,
            attribute.num_components() as u32,
            attribute.normalized() as u32,
            length as u32,
        ] {
            output.extend_from_slice(&n.to_le_bytes());
        }
        let source = attribute.buffer().data();
        for point in 0..mesh.num_points() {
            let index = attribute.mapped_index(PointIndex(point as u32)).0 as usize;
            if index >= attribute.size() {
                return Err(1);
            }
            let offset = index.checked_mul(stride).ok_or(1u32)?;
            output.extend_from_slice(source.get(offset..offset + stride).ok_or(1u32)?);
        }
    }
    Ok(output)
}

#[repr(C)]
pub struct MeshBytes {
    pub data: *mut u8,
    pub length: usize,
}

/// # Safety
/// Input and limits must be readable and output writable, valid and disjoint.
/// Output must start empty. Free the unchanged descriptor after use.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_draco_decode(
    input: *const u8,
    length: usize,
    limits: *const MeshLimits,
    output: *mut MeshBytes,
) -> u32 {
    if input.is_null() || limits.is_null() || output.is_null() || length == 0 {
        return 1;
    }
    let (limits, output) = unsafe { (&*limits, &mut *output) };
    if !output.data.is_null() || output.length != 0 {
        return 1;
    }
    if let Err(status) = limits.validate() {
        return status;
    }
    if length as u64 > limits.max_encoded_bytes {
        return 2;
    }
    let bytes = unsafe { std::slice::from_raw_parts(input, length) };
    match decode_draco(bytes, limits) {
        Ok(packet) => {
            let mut packet = packet.into_boxed_slice();
            output.length = packet.len();
            output.data = packet.as_mut_ptr();
            std::mem::forget(packet);
            0
        }
        Err(status) => status,
    }
}

/// # Safety
/// Pass only an unchanged descriptor returned above, or an empty descriptor.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_draco_free(output: *mut MeshBytes) {
    if output.is_null() {
        return;
    }
    let output = unsafe { &mut *output };
    if !output.data.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(
                output.data,
                output.length,
            )));
        }
    }
    output.data = std::ptr::null_mut();
    output.length = 0;
}
