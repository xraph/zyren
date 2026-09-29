static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
use zyren_runtime::compression::fg2_meshopt_decode;

fn encode_vertices(bytes: &[u8], stride: usize) -> Vec<u8> {
    let count = bytes.len() / stride;
    let mut encoded =
        vec![0; unsafe { meshopt::ffi::meshopt_encodeVertexBufferBound(count, stride) }];
    let length = unsafe {
        meshopt::ffi::meshopt_encodeVertexBuffer(
            encoded.as_mut_ptr(),
            encoded.len(),
            bytes.as_ptr().cast(),
            count,
            stride,
        )
    };
    assert!(length > 0);
    encoded.truncate(length);
    encoded
}

fn decode(input: &[u8], count: usize, stride: usize, mode: u32, filter: u32) -> (u32, Vec<u32>) {
    let mut output = vec![0xcdcdcdcd; (count * stride).div_ceil(4)];
    let status = unsafe {
        fg2_meshopt_decode(
            input.as_ptr(),
            input.len(),
            count,
            stride,
            mode,
            filter,
            output.as_mut_ptr().cast(),
            count * stride,
        )
    };
    (status, output)
}

#[test]
fn meshopt_vertices_round_trip() {
    let _guard = TEST_LOCK.lock().unwrap();
    let vertices: [f32; 9] = [-1., -1., 0., 1., -1., 0., 0., 1., 0.];
    let bytes = bytemuck::cast_slice(&vertices);
    let encoded = encode_vertices(bytes, 12);
    let (status, decoded) = decode(&encoded, 3, 12, 0, 0);
    assert_eq!(status, 0);
    assert_eq!(bytemuck::cast_slice::<u32, u8>(&decoded), bytes);
}

#[test]
fn meshopt_triangle_and_sequence_indices() {
    let _guard = TEST_LOCK.lock().unwrap();
    let indices = [0u32, 1, 2, 2, 1, 3];
    for mode in [1, 2] {
        let mut encoded = vec![0; 256];
        let length = unsafe {
            if mode == 1 {
                meshopt::ffi::meshopt_encodeIndexBuffer(
                    encoded.as_mut_ptr(),
                    encoded.len(),
                    indices.as_ptr(),
                    indices.len(),
                )
            } else {
                meshopt::ffi::meshopt_encodeIndexSequence(
                    encoded.as_mut_ptr(),
                    encoded.len(),
                    indices.as_ptr(),
                    indices.len(),
                )
            }
        };
        encoded.truncate(length);
        for stride in [2, 4] {
            let (status, output) = decode(&encoded, indices.len(), stride, mode, 0);
            assert_eq!(status, 0);
            let bytes: &[u8] = bytemuck::cast_slice(&output);
            let decoded: Vec<u32> = bytes[..indices.len() * stride]
                .chunks_exact(stride)
                .map(|v| {
                    if stride == 2 {
                        u16::from_le_bytes(v.try_into().unwrap()) as u32
                    } else {
                        u32::from_le_bytes(v.try_into().unwrap())
                    }
                })
                .collect();
            assert_eq!(decoded, indices);
        }
    }
}

#[test]
fn meshopt_filters_decode_known_vectors() {
    let _guard = TEST_LOCK.lock().unwrap();
    for (filter, stride) in [(1, 4), (1, 8), (2, 8), (3, 16)] {
        let source = [0f32, 0., 1., 0.];
        let mut filtered = [0u32; 4];
        unsafe {
            match filter {
                1 => meshopt::ffi::meshopt_encodeFilterOct(
                    filtered.as_mut_ptr().cast(),
                    1,
                    stride,
                    if stride == 4 { 8 } else { 16 },
                    source.as_ptr(),
                ),
                2 => meshopt::ffi::meshopt_encodeFilterQuat(
                    filtered.as_mut_ptr().cast(),
                    1,
                    stride,
                    16,
                    source.as_ptr(),
                ),
                _ => meshopt::ffi::meshopt_encodeFilterExp(
                    filtered.as_mut_ptr().cast(),
                    1,
                    stride,
                    24,
                    source.as_ptr(),
                    0,
                ),
            }
        }
        let encoded = encode_vertices(
            &bytemuck::cast_slice::<u32, u8>(&filtered)[..stride],
            stride,
        );
        let (status, output) = decode(&encoded, 1, stride, 0, filter);
        assert_eq!(status, 0);
        let bytes: &[u8] = bytemuck::cast_slice(&output);
        if filter == 3 {
            assert_eq!(bytemuck::cast_slice::<u32, f32>(&output), source);
        } else if stride == 4 {
            assert_eq!(&bytes[..4], &[0, 0, 127, 0]);
        } else {
            let components: &[i16] = bytemuck::cast_slice(&output);
            assert_eq!(&components[..4], &[0, 0, 32767, 0]);
        }
    }
}

#[test]
fn meshopt_rejects_truncated_corrupt_and_wrong_sized_streams() {
    let _guard = TEST_LOCK.lock().unwrap();
    let encoded = encode_vertices(&[0; 36], 12);
    for size in 0..encoded.len() {
        assert_eq!(decode(&encoded[..size], 3, 12, 0, 0).0, 1);
    }
    assert_eq!(decode(&[0; 20], 3, 12, 0, 0).0, 1);
    assert_eq!(decode(&encoded, 400, 12, 0, 0).0, 1);
}

#[test]
fn meshopt_invalid_layouts_leave_output_untouched() {
    let _guard = TEST_LOCK.lock().unwrap();
    let input = [0u8; 16];
    let mut output = [0xddddddddu32; 16];
    for (count, stride, mode, filter, length) in [
        (0, 4, 0, 0, 0),
        (1, 3, 0, 0, 3),
        (1, 260, 0, 0, 260),
        (1, 4, 9, 0, 4),
        (1, 4, 0, 9, 4),
        (4, 2, 1, 0, 8),
        (3, 4, 2, 1, 12),
        (1, 12, 0, 1, 12),
        (1, 4, 0, 2, 4),
        (3, 4, 0, 0, 11),
    ] {
        let status = unsafe {
            fg2_meshopt_decode(
                input.as_ptr(),
                input.len(),
                count,
                stride,
                mode,
                filter,
                output.as_mut_ptr().cast(),
                length,
            )
        };
        assert_eq!(status, 1);
        assert_eq!(output, [0xdddddddd; 16]);
    }
    let status = unsafe {
        fg2_meshopt_decode(
            input.as_ptr(),
            input.len(),
            usize::MAX,
            256,
            0,
            0,
            output.as_mut_ptr().cast(),
            64,
        )
    };
    assert_eq!(status, 2);
    assert_eq!(output, [0xdddddddd; 16]);
}

#[test]
fn meshopt_ffi_rejects_null_and_unaligned_output() {
    let _guard = TEST_LOCK.lock().unwrap();
    let mut output = [0u32; 8];
    let input = [0u8; 16];
    unsafe {
        assert_eq!(
            fg2_meshopt_decode(
                std::ptr::null(),
                16,
                3,
                4,
                0,
                0,
                output.as_mut_ptr().cast(),
                12
            ),
            1
        );
        assert_eq!(
            fg2_meshopt_decode(input.as_ptr(), 16, 3, 4, 0, 0, std::ptr::null_mut(), 12),
            1
        );
        assert_eq!(
            fg2_meshopt_decode(
                input.as_ptr(),
                16,
                3,
                4,
                0,
                0,
                output.as_mut_ptr().cast::<u8>().add(1),
                12
            ),
            1
        );
    }
}
