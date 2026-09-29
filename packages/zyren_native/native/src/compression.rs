use std::sync::atomic::{AtomicUsize, Ordering};

static ACTIVE: AtomicUsize = AtomicUsize::new(0);
struct Admission;
impl Drop for Admission {
    fn drop(&mut self) {
        ACTIVE.fetch_sub(1, Ordering::AcqRel);
    }
}

/// CPU-only meshoptimizer decoding into caller-owned memory.
/// Status: 0 success, 1 invalid data/layout, 2 limit exceeded, 3 busy.
/// Output may be partially written on malformed streams. Discard it on failure.
///
/// # Safety
/// Input and output must be disjoint, live allocations of the declared lengths.
/// Output must be aligned to four bytes. Ownership stays with the caller.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn fg2_meshopt_decode(
    input: *const u8,
    input_len: usize,
    count: usize,
    stride: usize,
    mode: u32,
    filter: u32,
    output: *mut u8,
    output_len: usize,
) -> u32 {
    if input.is_null()
        || output.is_null()
        || !(output as usize).is_multiple_of(4)
        || input_len == 0
        || count == 0
        || stride == 0
        || stride > 256
        || mode > 2
        || filter > 3
        || (mode == 0 && !stride.is_multiple_of(4))
        || (mode != 0 && ((stride != 2 && stride != 4) || filter != 0))
        || (mode == 1 && !count.is_multiple_of(3))
        || (filter == 1 && stride != 4 && stride != 8)
        || (filter == 2 && stride != 8)
    {
        return 1;
    }
    if input_len > 16 * 1024 * 1024 || count > 64 * 1024 * 1024 / stride {
        return 2;
    }
    if output_len != count * stride {
        return 1;
    }
    let Some(input_end) = (input as usize).checked_add(input_len) else {
        return 1;
    };
    let Some(output_end) = (output as usize).checked_add(output_len) else {
        return 1;
    };
    if (input as usize) < output_end && (output as usize) < input_end {
        return 1;
    }
    if ACTIVE
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
            (n < 2).then_some(n + 1)
        })
        .is_err()
    {
        return 3;
    }
    let _admission = Admission;
    // These codecs write into the checked output buffer and use fixed stack
    // workspace. They perform no heap allocation and accept untrusted bytes.
    let status = unsafe {
        match mode {
            0 => meshopt::ffi::meshopt_decodeVertexBuffer(
                output.cast(),
                count,
                stride,
                input,
                input_len,
            ),
            1 => meshopt::ffi::meshopt_decodeIndexBuffer(
                output.cast(),
                count,
                stride,
                input,
                input_len,
            ),
            _ => meshopt::ffi::meshopt_decodeIndexSequence(
                output.cast(),
                count,
                stride,
                input,
                input_len,
            ),
        }
    };
    if status != 0 {
        return 1;
    }
    unsafe {
        match filter {
            1 => meshopt::ffi::meshopt_decodeFilterOct(output.cast(), count, stride),
            2 => meshopt::ffi::meshopt_decodeFilterQuat(output.cast(), count, stride),
            3 => meshopt::ffi::meshopt_decodeFilterExp(output.cast(), count, stride),
            _ => {}
        }
    }
    0
}
