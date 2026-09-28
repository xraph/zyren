use basisu_c_sys::{
    BasisTextureFormat, common,
    extra::{types::Extent3d, *},
};

fn main() {
    basisu_encoder_init();
    basisu_encoder_enable_debug_printf(false);
    let directory =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../test_assets/compression");
    let pixels: Vec<u8> = (0..64)
        .flat_map(|i| {
            if i % 8 < 4 {
                [240, 20, 10, 255]
            } else {
                [10, 20, 240, 80]
            }
        })
        .collect();
    for (name, format, zstd) in [
        ("colors-etc1s.ktx2", BasisTextureFormat::Etc1s, false),
        ("colors-uastc.ktx2", BasisTextureFormat::UastcLdr4x4, false),
        ("colors-zstd.ktx2", BasisTextureFormat::UastcLdr4x4, true),
    ] {
        let mut encoder = BasisuEncoder::new();
        encoder
            .set_image(SourceImage {
                data: &pixels,
                format: SourceImageFormat::Rgba8,
                size: Extent3d {
                    width: 8,
                    height: 8,
                    depth_or_array_layers: 1,
                },
            })
            .unwrap();
        let mut params = BasisuEncoderParams::new_with_srgb_defaults(format)
            .with_flags(common::BU_COMP_FLAGS_GEN_MIPS_CLAMP)
            .with_removed_flags(common::BU_COMP_FLAGS_THREADED);
        if !zstd {
            params = params.with_removed_flags(common::BU_COMP_FLAGS_KTX2_UASTC_ZSTD);
        }
        let bytes = encoder.compress(params).unwrap();
        std::fs::write(directory.join(name), &bytes).unwrap();
        println!("{name}: {} bytes", bytes.len());
    }
}
