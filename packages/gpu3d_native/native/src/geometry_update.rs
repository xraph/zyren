use crate::scene::Geometry;

#[derive(Clone, PartialEq)]
pub struct AttributeRange {
    pub semantic: u32,
    pub first: u32,
    pub values: Vec<f32>,
}
impl AttributeRange {
    pub fn components(&self) -> usize {
        if self.semantic < 2 {
            3
        } else if self.semantic < 4 {
            2
        } else {
            4
        }
    }
    pub fn count(&self) -> usize {
        self.values.len() / self.components()
    }
}
#[derive(Clone, PartialEq)]
pub struct GeometryPatch {
    pub id: u32,
    pub base: u32,
    pub ranges: Vec<AttributeRange>,
}
impl GeometryPatch {
    pub fn apply(&self, base: &Geometry) -> Result<Geometry, String> {
        if base.topology != 0
            || self.id == self.base
            || base.id != self.base
            || self.ranges.is_empty()
            || self.ranges.len() > 64
        {
            return Err("invalid geometry patch identity or range count".into());
        }
        let mut previous = None;
        for range in &self.ranges {
            let count = range.count();
            if range.semantic > 4
                || count == 0
                || !range.values.len().is_multiple_of(range.components())
                || range.values.iter().any(|v| !v.is_finite())
                || (range.first as usize)
                    .checked_add(count)
                    .is_none_or(|end| end > base.positions.len())
            {
                return Err("invalid geometry attribute range".into());
            }
            if previous.is_some_and(|(semantic, end)| {
                range.semantic < semantic
                    || (range.semantic == semantic && (range.first as usize) < end)
            }) {
                return Err(
                    "geometry ranges must be ordered and non-overlapping per attribute".into(),
                );
            }
            previous = Some((range.semantic, range.first as usize + count));
            if (range.semantic == 2 && base.uv0.is_empty())
                || (range.semantic == 3 && base.uv1.is_empty())
                || (range.semantic == 4 && base.tangents.is_empty())
            {
                return Err("geometry patch cannot change its vertex layout".into());
            }
            if range.semantic == 1
                && range
                    .values
                    .chunks_exact(3)
                    .any(|v| glam::Vec3::new(v[0], v[1], v[2]).length_squared() < 1e-12)
            {
                return Err("geometry normals must be nonzero".into());
            }
        }
        let mut next = base.clone();
        next.id = self.id;
        for range in &self.ranges {
            for (offset, values) in range.values.chunks_exact(range.components()).enumerate() {
                let index = range.first as usize + offset;
                match range.semantic {
                    0 => next.positions[index].copy_from_slice(values),
                    1 => next.normals[index].copy_from_slice(values),
                    2 => next.uv0[index].copy_from_slice(values),
                    3 => next.uv1[index].copy_from_slice(values),
                    4 => next.tangents[index].copy_from_slice(values),
                    _ => unreachable!(),
                }
            }
        }
        next.validate()?;
        Ok(next)
    }
    // Native position/normal and UV0/UV1 pairs use interleaved buffers.
    pub fn gpu_ranges(&self) -> Vec<(u32, usize, usize)> {
        let mut result = Vec::new();
        for buffer in 0..3 {
            let mut ranges: Vec<_> = self
                .ranges
                .iter()
                .filter(|r| {
                    (if r.semantic < 2 {
                        0
                    } else if r.semantic < 4 {
                        1
                    } else {
                        2
                    }) == buffer
                })
                .map(|r| (r.first as usize, r.first as usize + r.count()))
                .collect();
            ranges.sort_unstable();
            for (first, end) in ranges {
                if let Some((old_buffer, _, old_end)) = result.last_mut()
                    && *old_buffer == buffer
                    && first <= *old_end
                {
                    *old_end = (*old_end).max(end);
                } else {
                    result.push((buffer, first, end));
                }
            }
        }
        result
    }
}
