use gpu3d_runtime::resources::image_decode::{DecodeError, DecodeLimits, decode_hdr};

static DECODE: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn mutated_hdr_inputs_never_panic_or_return_invalid_float_storage() {
    let _serial = DECODE.lock().unwrap();
    let original = fixture(
        "-Y 1 +X 8",
        &[2, 2, 0, 8, 136, 128, 136, 64, 136, 32, 136, 132],
    );
    let mut state = 0x91a7_c52d_u32;
    for iteration in 0..512 {
        let mut bytes = original.clone();
        for _ in 0..=iteration % 4 {
            state = state.wrapping_mul(1664525).wrapping_add(1013904223);
            let index = state as usize % bytes.len();
            bytes[index] ^= (state >> 24) as u8;
        }
        let result = std::panic::catch_unwind(|| {
            decode_hdr(
                &bytes,
                DecodeLimits {
                    max_decoded_bytes: 1024 * 1024,
                    max_working_bytes: 4 * 1024 * 1024,
                    ..DecodeLimits::default()
                },
            )
        })
        .expect("malformed HDR must return a typed error");
        if let Ok(image) = result {
            assert_eq!(
                image.pixels.len(),
                (image.width * image.height * 4) as usize
            );
            assert!(
                image
                    .pixels
                    .iter()
                    .all(|value| value.is_finite() && *value >= 0.)
            );
        }
    }
}

fn fixture(resolution: &str, payload: &[u8]) -> Vec<u8> {
    [
        format!("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n{resolution}\n").as_bytes(),
        payload,
    ]
    .concat()
}

#[test]
fn hdr_preserves_bright_values_black_and_all_eight_orientations() {
    let _serial = DECODE.lock().unwrap();
    let samples = [
        [128, 64, 32, 130],
        [128, 0, 0, 128],
        [0, 128, 0, 129],
        [0, 0, 128, 132],
        [255, 255, 255, 0],
        [128, 128, 128, 136],
    ];
    let expected = [
        2., 1., 0.5, 1., 0.5, 0., 0., 1., 0., 1., 0., 1., 0., 0., 8., 1., 0., 0., 0., 1., 128.,
        128., 128., 1.,
    ];
    for first in ["-Y", "+Y", "-X", "+X"] {
        for second in if first.ends_with('Y') {
            ["+X", "-X"]
        } else {
            ["-Y", "+Y"]
        } {
            let n = if first.ends_with('Y') { 2 } else { 3 };
            let m = if second.ends_with('Y') { 2 } else { 3 };
            let mut payload = Vec::new();
            for a in 0..n {
                for b in 0..m {
                    let (x, y) = if first.ends_with('Y') {
                        (
                            if second == "+X" { b } else { m - 1 - b },
                            if first == "-Y" { a } else { n - 1 - a },
                        )
                    } else {
                        (
                            if first == "+X" { a } else { n - 1 - a },
                            if second == "-Y" { b } else { m - 1 - b },
                        )
                    };
                    payload.extend_from_slice(&samples[y * 3 + x]);
                }
            }
            let decoded = decode_hdr(
                &fixture(&format!("{first} {n} {second} {m}"), &payload),
                DecodeLimits::default(),
            )
            .unwrap();
            assert_eq!((decoded.width, decoded.height), (3, 2));
            assert_eq!(decoded.pixels, expected, "{first} {second}");
        }
    }
}

#[test]
fn hdr_handles_modern_and_legacy_runs_and_exponent_extremes() {
    let _serial = DECODE.lock().unwrap();
    let modern = fixture(
        "-Y 1 +X 8",
        &[
            2, 2, 0, 8, 136, 128, 8, 0, 16, 32, 48, 64, 80, 96, 112, 136, 0, 136, 131,
        ],
    );
    let image = decode_hdr(&modern, DecodeLimits::default()).unwrap();
    assert_eq!(&image.pixels[..8], &[4., 0., 0., 1., 4., 0.5, 0., 1.]);
    let legacy = decode_hdr(
        &fixture("-Y 1 +X 258", &[128, 0, 0, 130, 1, 1, 1, 1, 1, 1, 1, 1]),
        DecodeLimits::default(),
    )
    .unwrap();
    assert_eq!(legacy.pixels.len(), 258 * 4);
    assert!(legacy.pixels.chunks_exact(4).all(|p| p == [2., 0., 0., 1.]));
    let extremes = decode_hdr(
        &fixture("-Y 1 +X 2", &[255, 1, 0, 255, 128, 0, 0, 1]),
        DecodeLimits::default(),
    )
    .unwrap();
    assert!(extremes.pixels[0].is_finite() && extremes.pixels[0] > 1e38);
    assert!(extremes.pixels[4] > 0. && extremes.pixels[4] < f32::MIN_POSITIVE);
}

#[test]
fn hdr_rejects_malformed_runs_truncation_headers_and_trailing_data() {
    let _serial = DECODE.lock().unwrap();
    for data in [
        fixture(
            "-Y 1 +X 8",
            &[2, 2, 0, 9, 136, 128, 136, 0, 136, 0, 136, 130],
        ),
        fixture("-Y 1 +X 8", &[2, 2, 0, 8, 0]),
        fixture("-Y 1 +X 8", &[2, 2, 0, 8, 137, 0]),
        fixture("-Y 1 +X 8", &[2, 2, 0, 8, 8, 0]),
        fixture("-Y 1 +X 2", &[1, 1, 1, 2]),
        fixture("-Y 1 +X 2", &[128, 0, 0, 130, 1, 1, 1, 2]),
        fixture("-Y 1 +X 1", &[128, 0, 0]),
        fixture("-Y 1 +X 1", &[128, 0, 0, 130, 0]),
        fixture("-Y 1 -Y 1", &[128, 0, 0, 130]),
        b"#?RADIANCE\n\n-Y 1 +X 1\n".to_vec(),
        b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 1\n".to_vec(),
    ] {
        assert_eq!(
            decode_hdr(&data, DecodeLimits::default()).unwrap_err(),
            DecodeError::InvalidData
        );
    }
    let base = fixture("-Y 1 +X 1", &[128, 0, 0, 130]);
    for length in 0..base.len() {
        assert!(decode_hdr(&base[..length], DecodeLimits::default()).is_err());
    }
}

#[test]
fn hdr_bounds_encoded_decoded_working_dimension_and_header_bytes() {
    let _serial = DECODE.lock().unwrap();
    let bytes = fixture("-Y 1 +X 2", &[128, 0, 0, 130, 128, 0, 0, 130]);
    for limits in [
        DecodeLimits {
            max_encoded_bytes: 1,
            ..DecodeLimits::default()
        },
        DecodeLimits {
            max_decoded_bytes: 31,
            ..DecodeLimits::default()
        },
        DecodeLimits {
            max_working_bytes: 64,
            ..DecodeLimits::default()
        },
        DecodeLimits {
            max_dimension: 1,
            ..DecodeLimits::default()
        },
    ] {
        assert_eq!(
            decode_hdr(&bytes, limits).unwrap_err(),
            DecodeError::LimitExceeded
        );
    }
    assert_eq!(
        decode_hdr(
            &fixture("-Y 4294967295 +X 4294967295", &[]),
            DecodeLimits::default()
        )
        .unwrap_err(),
        DecodeError::LimitExceeded
    );
    let huge_header = [b"#?RADIANCE\n#".as_slice(), &vec![b'a'; 65536], b"\n\n"].concat();
    assert_eq!(
        decode_hdr(&huge_header, DecodeLimits::default()).unwrap_err(),
        DecodeError::LimitExceeded
    );
}

#[test]
fn hdr_accepts_common_alias_and_preserves_stored_exposure_without_reapplying_it() {
    let _serial = DECODE.lock().unwrap();
    let bytes = [b"#?RGBE\r\nFORMAT=32-bit_rle_rgbe\r\nEXPOSURE=2\r\nCOLORCORR=2 1 1\r\nPRIMARIES=0.64 0.33 0.30 0.60 0.15 0.06 0.3127 0.3290\r\n\r\n-Y 1 +X 1\r\n".as_slice(), &[128, 64, 32, 130]].concat();
    assert_eq!(
        decode_hdr(&bytes, DecodeLimits::default()).unwrap().pixels,
        [2., 1., 0.5, 1.]
    );
    for (header, error) in [
        ("FORMAT=32-bit_rle_xyze", DecodeError::UnsupportedColor),
        (
            "FORMAT=32-bit_rle_rgbe\nPRIMARIES=0.64 0.33 0.29 0.60 0.15 0.06 0.333 0.333",
            DecodeError::UnsupportedColor,
        ),
        (
            "FORMAT=32-bit_rle_rgbe\nPIXASPECT=2",
            DecodeError::UnsupportedColor,
        ),
        (
            "FORMAT=32-bit_rle_rgbe\nEXPOSURE=NaN",
            DecodeError::InvalidData,
        ),
        (
            "FORMAT=32-bit_rle_rgbe\nCOLORCORR=0 1 1",
            DecodeError::InvalidData,
        ),
    ] {
        let input = [
            format!("#?RADIANCE\n{header}\n\n-Y 1 +X 1\n").as_bytes(),
            &[128, 0, 0, 130],
        ]
        .concat();
        assert_eq!(
            decode_hdr(&input, DecodeLimits::default()).unwrap_err(),
            error
        );
    }
}

#[test]
fn hdr_ffi_owns_float_pixels_and_clears_failed_descriptors() {
    use gpu3d_runtime::resources::image_decode::ffi::{
        HdrImagePixels, ImageLimits, fg2_hdr_image_decode, fg2_hdr_image_free,
    };
    let _serial = DECODE.lock().unwrap();
    let bytes = fixture("-Y 1 +X 1", &[128, 64, 32, 130]);
    let limits = ImageLimits::default();
    let mut output = HdrImagePixels::default();
    unsafe {
        assert_eq!(
            fg2_hdr_image_decode(bytes.as_ptr(), bytes.len(), &limits, &mut output),
            0
        );
        assert_eq!((output.width, output.height, output.length), (1, 1, 4));
        assert_eq!(
            std::slice::from_raw_parts(output.pixels, output.length),
            [2., 1., 0.5, 1.]
        );
        fg2_hdr_image_free(&mut output);
        assert!(output.pixels.is_null());
        assert_eq!(output.length, 0);
        fg2_hdr_image_free(&mut output);
        fg2_hdr_image_free(std::ptr::null_mut());
        assert_eq!(
            fg2_hdr_image_decode(std::ptr::null(), bytes.len(), &limits, &mut output),
            1
        );
        assert_eq!(
            fg2_hdr_image_decode(bytes.as_ptr(), bytes.len(), std::ptr::null(), &mut output),
            1
        );
        assert_eq!(
            fg2_hdr_image_decode(bytes.as_ptr(), bytes.len(), &limits, std::ptr::null_mut()),
            1
        );
        assert_eq!(
            fg2_hdr_image_decode(bytes.as_ptr(), usize::MAX, &limits, &mut output),
            4
        );
        assert_eq!(
            fg2_hdr_image_decode(
                bytes.as_ptr(),
                bytes.len(),
                &ImageLimits {
                    version: 2,
                    ..limits
                },
                &mut output
            ),
            7
        );
        assert!(output.pixels.is_null());
    }
}
