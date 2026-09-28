use gpu3d_runtime::resources::image_decode::{DecodeError, DecodeLimits, decode};
use image::{
    ExtendedColorType, ImageEncoder,
    codecs::{jpeg::JpegEncoder, png::PngEncoder},
};
static DECODE_TEST: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[test]
fn png_output_and_decoder_workspace_share_the_working_allowance() {
    let _serial = DECODE_TEST.lock().unwrap();
    let bytes = png();
    // The stream and pixels fit, but the decoder still needs its DEFLATE
    // window, row buffers and metadata bookkeeping.
    assert_eq!(
        decode(
            &bytes,
            DecodeLimits {
                max_working_bytes: bytes.len() as u64 * 2 + 16 + 32 * 1024,
                ..Default::default()
            },
        )
        .unwrap_err(),
        DecodeError::LimitExceeded,
    );
    let image = decode(
        &bytes,
        DecodeLimits {
            max_working_bytes: 2 * 1024 * 1024,
            ..Default::default()
        },
    )
    .unwrap();
    assert_eq!(
        image.pixels,
        [
            255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 255, 0, 255, 255, 255, 255
        ]
    );
}

fn png() -> Vec<u8> {
    let mut bytes = Vec::new();
    PngEncoder::new(&mut bytes)
        .write_image(
            &[
                255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 255, 0, 255, 255, 255, 255,
            ],
            2,
            2,
            ExtendedColorType::Rgba8,
        )
        .unwrap();
    bytes
}

#[test]
fn png_preserves_straight_alpha_and_top_down_pixels() {
    let _serial = DECODE_TEST.lock().unwrap();
    let image = decode(&png(), DecodeLimits::default()).unwrap();
    assert_eq!((image.width, image.height), (2, 2));
    assert_eq!(
        image.pixels,
        [
            255, 0, 0, 128, 0, 255, 0, 255, 0, 0, 255, 0, 255, 255, 255, 255
        ]
    );
}

#[test]
fn jpeg_converts_rgb_to_opaque_rgba() {
    let _serial = DECODE_TEST.lock().unwrap();
    let mut bytes = Vec::new();
    JpegEncoder::new_with_quality(&mut bytes, 100)
        .encode(&[128; 3 * 8 * 8], 8, 8, ExtendedColorType::Rgb8)
        .unwrap();
    let image = decode(&bytes, DecodeLimits::default()).unwrap();
    assert_eq!((image.width, image.height), (8, 8));
    for pixel in image.pixels.chunks_exact(4) {
        assert!((127..=129).contains(&pixel[0]));
        assert_eq!(pixel[0], pixel[1]);
        assert_eq!(pixel[1], pixel[2]);
        assert_eq!(pixel[3], 255);
    }
    assert!(decode(&bytes[..bytes.len() / 2], DecodeLimits::default()).is_err());
}

#[test]
fn compressed_extent_output_and_working_limits_apply_before_allocation() {
    let _serial = DECODE_TEST.lock().unwrap();
    let bytes = png();
    for limits in [
        DecodeLimits {
            max_encoded_bytes: bytes.len() as u64 - 1,
            ..Default::default()
        },
        DecodeLimits {
            max_dimension: 1,
            ..Default::default()
        },
        DecodeLimits {
            max_decoded_bytes: 15,
            ..Default::default()
        },
        DecodeLimits {
            max_working_bytes: 16,
            ..Default::default()
        },
    ] {
        assert_eq!(
            decode(&bytes, limits).unwrap_err(),
            DecodeError::LimitExceeded
        );
    }
    assert_eq!(
        decode(
            &bytes,
            DecodeLimits {
                max_dimension: 0,
                ..Default::default()
            }
        )
        .unwrap_err(),
        DecodeError::InvalidLimits
    );
}

#[test]
fn truncated_unsupported_and_deep_color_images_fail() {
    let _serial = DECODE_TEST.lock().unwrap();
    let bytes = png();
    for end in 0..bytes.len() - 12 {
        assert!(
            decode(&bytes[..end], DecodeLimits::default()).is_err(),
            "end {end}"
        );
    }
    assert_eq!(
        decode(b"GIF89a", DecodeLimits::default()).unwrap_err(),
        DecodeError::UnsupportedFormat
    );
    let mut bytes = Vec::new();
    PngEncoder::new(&mut bytes)
        .write_image(&[0, 1], 1, 1, ExtendedColorType::L16)
        .unwrap();
    assert_eq!(
        decode(&bytes, DecodeLimits::default()).unwrap_err(),
        DecodeError::UnsupportedColor
    );
}

#[test]
fn jpeg_workspace_and_premature_scan_are_rejected() {
    let _serial = DECODE_TEST.lock().unwrap();
    let bytes = include_bytes!("../../../../test_assets/images/gray.jpg");
    assert_eq!(
        decode(
            bytes,
            DecodeLimits {
                max_working_bytes: bytes.len() as u64 * 2 + 8 * 8 * 7,
                ..Default::default()
            }
        )
        .unwrap_err(),
        DecodeError::LimitExceeded
    );
    let scan = bytes.windows(2).position(|b| b == [0xff, 0xda]).unwrap();
    let length = u16::from_be_bytes([bytes[scan + 2], bytes[scan + 3]]) as usize;
    let mut truncated = bytes[..scan + 2 + length].to_vec();
    truncated.extend_from_slice(&[0xff, 0xd9]);
    assert!(decode(&truncated, DecodeLimits::default()).is_err());
}

#[test]
fn corrupt_png_terminal_crc_is_rejected() {
    let _serial = DECODE_TEST.lock().unwrap();
    let mut bytes = png();
    *bytes.last_mut().unwrap() ^= 1;
    assert_eq!(
        decode(&bytes, DecodeLimits::default()).unwrap_err(),
        DecodeError::InvalidData
    );
}

#[test]
fn progressive_jpeg_and_grayscale_png_expand_to_rgba() {
    let _serial = DECODE_TEST.lock().unwrap();
    let jpeg = include_bytes!("../../../../test_assets/images/gray-progressive.jpg");
    let image = decode(jpeg, DecodeLimits::default()).unwrap();
    assert_eq!(image.pixels.len(), 8 * 8 * 4);
    assert!((127..=129).contains(&image.pixels[0]));
    assert_eq!(image.pixels[3], 255);
    for (color, input, expected) in [
        (ExtendedColorType::L8, vec![37], vec![37, 37, 37, 255]),
        (ExtendedColorType::La8, vec![37, 61], vec![37, 37, 37, 61]),
    ] {
        let mut bytes = Vec::new();
        PngEncoder::new(&mut bytes)
            .write_image(&input, 1, 1, color)
            .unwrap();
        assert_eq!(
            decode(&bytes, DecodeLimits::default()).unwrap().pixels,
            expected
        );
    }
}

#[test]
fn hostile_png_extents_animation_and_seeded_mutations_are_bounded() {
    let _serial = DECODE_TEST.lock().unwrap();
    let original = png();
    for dimension in [4097_u32, u32::MAX] {
        let mut bytes = original.clone();
        bytes[16..20].copy_from_slice(&dimension.to_be_bytes());
        let crc = crc32fast::hash(&bytes[12..29]);
        bytes[29..33].copy_from_slice(&crc.to_be_bytes());
        assert!(decode(&bytes, DecodeLimits::default()).is_err());
    }
    let mut animated = original[..33].to_vec();
    animated.extend_from_slice(&8_u32.to_be_bytes());
    animated.extend_from_slice(b"acTL");
    animated.extend_from_slice(&[0, 0, 0, 1, 0, 0, 0, 0]);
    let crc = crc32fast::hash(&animated[37..]);
    animated.extend_from_slice(&crc.to_be_bytes());
    animated.extend_from_slice(&original[33..]);
    assert_eq!(
        decode(&animated, DecodeLimits::default()).unwrap_err(),
        DecodeError::UnsupportedFormat
    );
    // Repeatable parser coverage for both formats, including segment/chunk lengths.
    let mut seed = 0x942a_7281_u32;
    for input in [
        &original[..],
        &include_bytes!("../../../../test_assets/images/gray-progressive.jpg")[..],
    ] {
        for _ in 0..256 {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            let mut bytes = input.to_vec();
            let index = seed as usize % bytes.len();
            bytes[index] ^= (seed >> 24) as u8 | 1;
            let result = decode(
                &bytes,
                DecodeLimits {
                    max_dimension: 64,
                    max_decoded_bytes: 64 * 64 * 4,
                    max_working_bytes: 4 * 1024 * 1024,
                    ..Default::default()
                },
            );
            if let Ok(image) = result {
                assert_eq!(
                    image.pixels.len(),
                    image.width as usize * image.height as usize * 4
                );
                assert!(image.pixels.len() <= 64 * 64 * 4);
            }
        }
    }
    assert!(decode(&original, DecodeLimits::default()).is_ok());
}
