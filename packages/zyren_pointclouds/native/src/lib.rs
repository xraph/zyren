use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::Cursor,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
};

type Result<T> = std::result::Result<T, Failure>;
#[derive(Debug)]
struct Failure(u8, String);
fn invalid(e: impl std::fmt::Display) -> Failure {
    Failure(1, e.to_string())
}
fn limit() -> Failure {
    Failure(2, "Point source exceeds its decode budget".into())
}
fn jobs() -> &'static Mutex<HashMap<u64, Arc<AtomicBool>>> {
    static JOBS: OnceLock<Mutex<HashMap<u64, Arc<AtomicBool>>>> = OnceLock::new();
    JOBS.get_or_init(|| Mutex::new(HashMap::new()))
}
#[unsafe(no_mangle)]
pub extern "C" fn zyren_points_job_create() -> u64 {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    jobs()
        .lock()
        .unwrap()
        .insert(id, Arc::new(AtomicBool::new(false)));
    id
}
#[unsafe(no_mangle)]
pub extern "C" fn zyren_points_job_cancel(id: u64) {
    if let Some(flag) = jobs().lock().unwrap().get(&id) {
        flag.store(true, Ordering::Relaxed);
    }
}
#[unsafe(no_mangle)]
pub extern "C" fn zyren_points_job_free(id: u64) {
    jobs().lock().unwrap().remove(&id);
}
fn check(flag: &AtomicBool) -> Result<()> {
    if flag.load(Ordering::Relaxed) {
        Err(Failure(3, "Point decoding cancelled".into()))
    } else {
        Ok(())
    }
}

// The first byte is a status. Successful payloads contain a little-endian
// count, metadata length, skipped count, JSON metadata, then records. A record
// is xyz:f64[3], ordinal:u64, scan:u32, attribute length:u32, JSON attributes.
struct Output {
    bytes: Vec<u8>,
    max: usize,
    count: u32,
    skipped: u32,
}
impl Output {
    fn new(metadata: Value, max: usize) -> Result<Self> {
        let meta = serde_json::to_vec(&metadata).map_err(invalid)?;
        if meta.len() > 4 * 1024 * 1024 || meta.len() + 13 > max {
            return Err(limit());
        }
        let mut bytes = vec![0; 13];
        bytes[5..9].copy_from_slice(&(meta.len() as u32).to_le_bytes());
        bytes.extend(meta);
        Ok(Self {
            bytes,
            max,
            count: 0,
            skipped: 0,
        })
    }
    fn point(&mut self, xyz: [f64; 3], ordinal: u64, scan: u32, attributes: Value) -> Result<()> {
        if xyz.iter().any(|n| !n.is_finite()) {
            return Err(invalid("Non-finite point coordinate"));
        }
        let attrs = serde_json::to_vec(&attributes).map_err(invalid)?;
        if attrs.len() > 65536 || self.bytes.len() + 40 + attrs.len() > self.max {
            return Err(limit());
        }
        for v in xyz {
            self.bytes.extend(v.to_le_bytes());
        }
        self.bytes.extend(ordinal.to_le_bytes());
        self.bytes.extend(scan.to_le_bytes());
        self.bytes.extend((attrs.len() as u32).to_le_bytes());
        self.bytes.extend(attrs);
        self.count += 1;
        Ok(())
    }
    fn finish(mut self) -> Result<Vec<u8>> {
        if self.count == 0 {
            return Err(invalid("Source contains no valid positional samples"));
        }
        self.bytes[1..5].copy_from_slice(&self.count.to_le_bytes());
        self.bytes[9..13].copy_from_slice(&self.skipped.to_le_bytes());
        Ok(self.bytes)
    }
}
fn u16_at(b: &[u8], p: usize) -> Result<u16> {
    Ok(u16::from_le_bytes(
        b.get(p..p + 2)
            .ok_or_else(|| invalid("Truncated source"))?
            .try_into()
            .unwrap(),
    ))
}
fn u32_at(b: &[u8], p: usize) -> Result<u32> {
    Ok(u32::from_le_bytes(
        b.get(p..p + 4)
            .ok_or_else(|| invalid("Truncated source"))?
            .try_into()
            .unwrap(),
    ))
}
fn u64_at(b: &[u8], p: usize) -> Result<u64> {
    Ok(u64::from_le_bytes(
        b.get(p..p + 8)
            .ok_or_else(|| invalid("Truncated source"))?
            .try_into()
            .unwrap(),
    ))
}
fn checked_region(b: &[u8], offset: u64, length: u64) -> Result<()> {
    if offset
        .checked_add(length)
        .is_none_or(|end| end > b.len() as u64)
    {
        Err(invalid("Section exceeds source length"))
    } else {
        Ok(())
    }
}
fn preflight_las(b: &[u8], max_points: usize) -> Result<()> {
    if b.len() < 227 || b[24] != 1 || b[25] > 4 {
        return Err(invalid("Expected LAS 1.0 through 1.4"));
    }
    let header = u16_at(b, 94)? as usize;
    let offset = u32_at(b, 96)? as usize;
    let min_header = if b[25] == 4 {
        375
    } else if b[25] == 3 {
        235
    } else {
        227
    };
    if header < min_header || offset < header || offset > b.len() {
        return Err(invalid("Invalid LAS header or point offset"));
    }
    let extended = if b[25] == 4 { u64_at(b, 247)? } else { 0 };
    let count = if extended > 0 {
        extended
    } else {
        u32_at(b, 107)? as u64
    };
    if count == 0 {
        return Err(invalid("Empty LAS source"));
    }
    if count > max_points as u64 {
        return Err(limit());
    }
    let stride = u16_at(b, 105)? as u64;
    if stride < 20 {
        return Err(invalid("Invalid LAS record length"));
    }
    if b[104] & 128 == 0 {
        checked_region(
            b,
            offset as u64,
            count.checked_mul(stride).ok_or_else(limit)?,
        )?;
    }
    let mut p = header;
    let mut laz_vlr = None;
    let vlrs = u32_at(b, 100)?;
    if vlrs > 65536 {
        return Err(limit());
    }
    for _ in 0..vlrs {
        checked_region(b, p as u64, 54)?;
        let len = u16_at(b, p + 20)? as usize;
        checked_region(b, p as u64 + 54, len as u64)?;
        if &b[p + 2..p + 16] == b"laszip encoded" && u16_at(b, p + 18)? == 22204 {
            if laz_vlr.is_some() {
                return Err(invalid("Duplicate LASzip VLR"));
            }
            laz_vlr = Some(&b[p + 54..p + 54 + len]);
        }
        p = p.checked_add(54 + len).ok_or_else(limit)?;
        if p > offset {
            return Err(invalid("LAS VLR overlaps point data"));
        }
    }
    if b[104] & 128 != 0 {
        preflight_laz(
            b,
            offset,
            stride,
            count,
            laz_vlr.ok_or_else(|| invalid("Missing LASzip VLR"))?,
        )?;
    }
    if b[25] == 4 {
        let mut evlr = u64_at(b, 235)?;
        let n = u32_at(b, 243)?;
        if n > 65536 {
            return Err(limit());
        }
        for _ in 0..n {
            checked_region(b, evlr, 60)?;
            let len = u64_at(b, evlr as usize + 20)?;
            if len > 4 * 1024 * 1024 {
                return Err(limit());
            }
            checked_region(b, evlr + 60, len)?;
            evlr += 60 + len;
        }
    }
    Ok(())
}
fn preflight_laz(b: &[u8], offset: usize, stride: u64, count: u64, vlr_bytes: &[u8]) -> Result<()> {
    use laz::LazItemType::*;
    let vlr = laz::LazVlr::read_from(Cursor::new(vlr_bytes)).map_err(invalid)?;
    if vlr.items().len() > 16 || vlr.items_size() != stride || stride > 4096 {
        return Err(limit());
    }
    let compressor = u16_at(vlr_bytes, 0)?;
    if compressor == 1 {
        return Ok(());
    }
    let mut table = u64_at(b, offset)?;
    if table == u64::MAX {
        table = u64_at(b, b.len().checked_sub(8).ok_or_else(limit)?)?;
    }
    checked_region(b, table, 8)?;
    if table <= offset as u64 {
        return Err(invalid("Bounded LAZ decoding requires a chunk table"));
    }
    if u32_at(b, table as usize + 4)? as u64 > count {
        return Err(limit());
    }
    let mut cursor = Cursor::new(b);
    cursor.set_position(offset as u64);
    let chunks = laz::laszip::ChunkTable::read_from(cursor, &vlr).map_err(invalid)?;
    let mut start = offset as u64 + 8;
    let mut records = 0u64;
    for chunk in chunks.as_ref() {
        checked_region(b, start, chunk.byte_count)?;
        if start + chunk.byte_count > table {
            return Err(invalid("LAZ chunk overlaps chunk table"));
        }
        records = records.checked_add(chunk.point_count).ok_or_else(limit)?;
        if compressor == 3 {
            let mut layers = 0usize;
            for item in vlr.items() {
                layers += match item.item_type() {
                    Point14 => 9,
                    RGB14 => 1,
                    RGBNIR14 => 2,
                    WavePacket14 => 1,
                    Byte14(n) => n as usize,
                    _ => return Err(invalid("Invalid layered LAZ item")),
                };
            }
            let sizes = start as usize + stride as usize + 4;
            let n = u32_at(b, sizes - 4)? as u64;
            if n == 0 || n > count {
                return Err(limit());
            }
            let mut payload = (stride + 4)
                .checked_add(layers as u64 * 4)
                .ok_or_else(limit)?;
            for i in 0..layers {
                payload = payload
                    .checked_add(u32_at(b, sizes + i * 4)? as u64)
                    .ok_or_else(limit)?;
            }
            if payload > chunk.byte_count {
                return Err(invalid("LAZ layer exceeds its chunk"));
            }
        }
        start += chunk.byte_count;
    }
    if records < count {
        return Err(invalid("LAZ chunk table has too few records"));
    }
    Ok(())
}
fn decode_las(
    b: Vec<u8>,
    max_points: usize,
    max_bytes: usize,
    flag: &AtomicBool,
) -> Result<Vec<u8>> {
    preflight_las(&b, max_points)?;
    check(flag)?;
    let mut reader = las::Reader::new(Cursor::new(b)).map_err(invalid)?;
    let h = reader.header();
    let t = h.transforms();
    let vlrs: Vec<_> = h.vlrs().iter().chain(h.evlrs()).map(|v| json!({"userId":v.user_id,"recordId":v.record_id,"description":v.description,"data":v.data})).collect();
    let wkt = h
        .vlrs()
        .iter()
        .chain(h.evlrs())
        .find(|v| v.user_id == "LASF_Projection" && v.record_id == 2112)
        .map(|v| {
            String::from_utf8_lossy(&v.data)
                .trim_end_matches('\0')
                .to_string()
        });
    let mut out = Output::new(
        json!({"format":if h.point_format().is_compressed {"LAZ"} else {"LAS"},"version":h.version().to_string(),"pointFormat":h.point_format().to_u8().map_err(invalid)?,"scale":[t.x.scale,t.y.scale,t.z.scale],"offset":[t.x.offset,t.y.offset,t.z.offset],"coordinateReferenceWkt":wkt,"units":null,"sourceRecords":h.number_of_points(),"vlrs":vlrs,"waveformSamplesDecoded":false}),
        max_bytes,
    )?;
    let expected = h.number_of_points();
    for (ordinal, point) in reader.points().enumerate() {
        check(flag)?;
        if ordinal >= max_points {
            return Err(limit());
        }
        let p = point.map_err(invalid)?;
        if p.gps_time.is_some_and(|v| !v.is_finite()) || !p.scan_angle.is_finite() {
            return Err(invalid("Non-finite LAS attribute"));
        }
        let waveform = p.waveform.map(|w| json!({"descriptorIndex":w.wave_packet_descriptor_index,"offset":w.byte_offset_to_waveform_data,"size":w.waveform_packet_size_in_bytes,"location":w.return_point_waveform_location,"xt":w.x_t,"yt":w.y_t,"zt":w.z_t}));
        out.point([p.x,p.y,p.z],ordinal as u64,0,json!({"classification":u8::from(p.classification),"intensity":p.intensity,"returnNumber":p.return_number,"returnCount":p.number_of_returns,"synthetic":p.is_synthetic,"keyPoint":p.is_key_point,"withheld":p.is_withheld,"overlap":p.is_overlap,"scannerChannel":p.scanner_channel,"sourceId":p.point_source_id,"scanAngle":p.scan_angle,"scanDirection":format!("{:?}",p.scan_direction),"edgeOfFlightLine":p.is_edge_of_flight_line,"userData":p.user_data,"gpsTime":p.gps_time,"color":p.color.map(|c|[c.red,c.green,c.blue]),"nir":p.nir,"extraBytes":p.extra_bytes,"waveform":waveform}))?;
    }
    if out.count as u64 != expected {
        return Err(invalid("Truncated LAS point stream"));
    }
    out.finish()
}
fn raw_json(v: &e57::RecordValue) -> Result<Value> {
    use e57::RecordValue::*;
    Ok(match v {
        Integer(v) | ScaledInteger(v) => json!(v),
        Single(v) if v.is_finite() => json!(v),
        Double(v) if v.is_finite() => json!(v),
        _ => return Err(invalid("Non-finite E57 attribute")),
    })
}
fn decode_e57(
    b: Vec<u8>,
    max_points: usize,
    max_bytes: usize,
    flag: &AtomicBool,
) -> Result<Vec<u8>> {
    if u64_at(&b, 40)? != 1024 || u64_at(&b, 16)? != b.len() as u64 {
        return Err(invalid("Invalid E57 physical length or page size"));
    }
    let xml_len = u64_at(&b, 32)?;
    if xml_len > 4 * 1024 * 1024 {
        return Err(limit());
    }
    checked_region(&b, u64_at(&b, 24)?, xml_len)?;
    let mut reader = e57::E57Reader::new(Cursor::new(b)).map_err(invalid)?;
    check(flag)?;
    let scans = reader.pointclouds();
    if scans.len() > 4096 || scans.iter().any(|p| p.prototype.len() > 256) {
        return Err(limit());
    }
    let total = scans
        .iter()
        .try_fold(0u64, |sum, p| sum.checked_add(p.records))
        .ok_or_else(limit)?;
    if total > max_points as u64 {
        return Err(limit());
    }
    let metadata: Vec<_> = scans.iter().map(|p| {
        let prototype: Vec<_> = p.prototype.iter().map(|r| {
            let ty = match r.data_type {
                e57::RecordDataType::ScaledInteger{min,max,scale,offset} => json!({"type":"scaledInteger","min":min,"max":max,"scale":scale,"offset":offset}),
                e57::RecordDataType::Integer{min,max} => json!({"type":"integer","min":min,"max":max}),
                e57::RecordDataType::Single{min,max} => json!({"type":"single","min":min,"max":max}),
                e57::RecordDataType::Double{min,max} => json!({"type":"double","min":min,"max":max}),
            };
            json!({"name":format!("{:?}",r.name),"dataType":ty})
        }).collect();
        json!({"guid":p.guid,"name":p.name,"records":p.records,"prototype":prototype,"pose":p.transform.as_ref().map(|t| json!({"rotation":[t.rotation.x,t.rotation.y,t.rotation.z,t.rotation.w],"translation":[t.translation.x,t.translation.y,t.translation.z]}))})
    }).collect();
    let mut out = Output::new(
        json!({"format":"E57","guid":reader.guid(),"coordinateReferenceWkt":reader.coordinate_metadata(),"units":"metres","sourceRecords":total,"scans":metadata,"poseApplied":true}),
        max_bytes,
    )?;
    let mut ordinal = 0u64;
    for (scan_index, scan) in scans.iter().enumerate() {
        if scan.prototype.len() > 256 {
            return Err(limit());
        }
        let raw = reader.pointcloud_raw(scan).map_err(invalid)?;
        let mut scanned = 0u64;
        for values in raw {
            check(flag)?;
            if scanned >= scan.records {
                return Err(invalid("E57 record count mismatch"));
            }
            let values = values.map_err(invalid)?;
            if values.len() != scan.prototype.len() {
                return Err(invalid("E57 prototype mismatch"));
            }
            let get = |name| -> Result<Option<f64>> {
                match scan.prototype.iter().position(|r| r.name == name) {
                    Some(i) => Ok(Some(
                        values[i]
                            .to_f64(&scan.prototype[i].data_type)
                            .map_err(invalid)?,
                    )),
                    None => Ok(None),
                }
            };
            use e57::RecordName::*;
            let cart = [get(CartesianX)?, get(CartesianY)?, get(CartesianZ)?];
            let spherical = [
                get(SphericalRange)?,
                get(SphericalAzimuth)?,
                get(SphericalElevation)?,
            ];
            let xyz = if let ([Some(x), Some(y), Some(z)], true) =
                (cart, get(CartesianInvalidState)?.unwrap_or(0.) == 0.)
            {
                Some([x, y, z])
            } else if let ([Some(r), Some(a), Some(e)], true) =
                (spherical, get(SphericalInvalidState)?.unwrap_or(0.) == 0.)
            {
                Some([r * e.cos() * a.cos(), r * e.cos() * a.sin(), r * e.sin()])
            } else {
                None
            };
            if let Some(mut xyz) = xyz {
                if let Some(t) = &scan.transform {
                    let q = &t.rotation;
                    let norm = q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w;
                    if !norm.is_finite() || (norm - 1.).abs() > 1e-6 {
                        return Err(invalid("E57 pose quaternion is not normalized"));
                    }
                    let [x, y, z] = xyz;
                    let tx = 2. * (q.y * z - q.z * y);
                    let ty = 2. * (q.z * x - q.x * z);
                    let tz = 2. * (q.x * y - q.y * x);
                    xyz = [
                        x + q.w * tx + q.y * tz - q.z * ty + t.translation.x,
                        y + q.w * ty + q.z * tx - q.x * tz + t.translation.y,
                        z + q.w * tz + q.x * ty - q.y * tx + t.translation.z,
                    ];
                }
                let attrs: Vec<Value> = values.iter().map(raw_json).collect::<Result<_>>()?;
                let intensity = if get(IsIntensityInvalid)?.unwrap_or(0.) == 0. {
                    get(Intensity)?
                } else {
                    None
                };
                let color = if get(IsColorInvalid)?.unwrap_or(0.) == 0. {
                    Some([get(ColorRed)?, get(ColorGreen)?, get(ColorBlue)?])
                } else {
                    None
                };
                out.point(xyz,ordinal,scan_index as u32,json!({"scanRecordIndex":scanned,"rawValues":attrs,"intensity":intensity,"color":color,"returnNumber":get(ReturnIndex)?.map(|v|v+1.),"returnCount":get(ReturnCount)?,"timeStampSinceScanStart":if get(IsTimeStampInvalid)?.unwrap_or(0.) == 0. {get(TimeStamp)?} else {None}}))?;
            } else {
                out.skipped += 1;
            }
            scanned += 1;
            ordinal += 1;
        }
        if scanned != scan.records {
            return Err(invalid("Truncated E57 point stream"));
        }
    }
    out.finish()
}
fn decode(b: Vec<u8>, max_points: usize, max_bytes: usize, flag: &AtomicBool) -> Result<Vec<u8>> {
    check(flag)?;
    if max_points == 0 || max_points > 250000 || max_bytes > 128 * 1024 * 1024 {
        return Err(limit());
    }
    if b.starts_with(b"LASF") {
        decode_las(b, max_points, max_bytes, flag)
    } else if b.starts_with(b"ASTM-E57") {
        decode_e57(b, max_points, max_bytes, flag)
    } else {
        Err(invalid("Expected a LAS, LAZ or E57 source"))
    }
}
/// The caller owns input until return and frees the returned allocation using
/// zyren_points_free with exactly the returned length. Calls may run concurrently.
///
/// # Safety
/// Input must reference len readable bytes and out_len must be writable. The
/// allocation returned here must be released exactly once by zyren_points_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zyren_points_decode(
    id: u64,
    input: *const u8,
    len: usize,
    max_points: usize,
    max_bytes: usize,
    out_len: *mut usize,
) -> *mut u8 {
    let result = std::panic::catch_unwind(|| {
        if input.is_null() || len > 128 * 1024 * 1024 {
            return Err(limit());
        }
        let flag = jobs()
            .lock()
            .unwrap()
            .get(&id)
            .cloned()
            .ok_or_else(|| invalid("Unknown decode job"))?;
        let b = unsafe { std::slice::from_raw_parts(input, len) }.to_vec();
        decode(b, max_points, max_bytes, &flag)
    })
    .unwrap_or_else(|_| Err(invalid("Malformed native point source")));
    let bytes = match result {
        Ok(v) => v,
        Err(Failure(code, message)) => {
            let mut v = vec![code];
            v.extend(message.bytes().take(4096));
            v
        }
    };
    let mut boxed = bytes.into_boxed_slice();
    unsafe {
        *out_len = boxed.len();
    }
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    ptr
}
/// Releases one result allocation.
///
/// # Safety
/// ptr and len must be the unmodified result of zyren_points_decode, and no
/// thread may read the allocation after this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zyren_points_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const LAS: &[u8] = include_bytes!("../../test/fixtures/survey.las");
    const LAZ: &[u8] = include_bytes!("../../test/fixtures/survey.laz");
    const E57: &[u8] = include_bytes!("../../test/fixtures/scans.e57");
    #[test]
    fn truncated_corpus_is_rejected_without_unwinding() {
        let flag = AtomicBool::new(false);
        for b in [LAS, LAZ, E57] {
            for len in (0..b.len()).step_by(19) {
                assert!(decode(b[..len].to_vec(), 250000, 64 * 1024 * 1024, &flag).is_err());
            }
        }
    }
    #[test]
    fn admission_and_cancel_precede_decode() {
        let flag = AtomicBool::new(true);
        assert_eq!(
            decode(LAZ.to_vec(), 250000, 64000000, &flag).unwrap_err().0,
            3
        );
        let flag = AtomicBool::new(false);
        assert_eq!(decode(LAS.to_vec(), 1, 64000000, &flag).unwrap_err().0, 2);
        let mut b = LAZ.to_vec();
        let offset = u32_at(&b, 96).unwrap() as usize;
        let table = u64_at(&b, offset).unwrap() as usize;
        b[table + 4..table + 8].copy_from_slice(&u32::MAX.to_le_bytes());
        assert_eq!(decode(b, 250000, 64000000, &flag).unwrap_err().0, 2);
    }
}
