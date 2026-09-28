use zyren_runtime::resources::image_decode::ffi::{
    ImageLimits, ImagePixels, fg2_image_decode, fg2_image_free,
};

#[test]
fn image_ffi_returns_owned_pixels_and_clears_failed_outputs() {
    let png = include_bytes!("../../../../test_assets/images/corners.png");
    let limits = ImageLimits::default();
    let mut output = ImagePixels::default();
    unsafe {
        assert_eq!(
            fg2_image_decode(png.as_ptr(), png.len(), &limits, &mut output),
            0
        );
        assert_eq!((output.width, output.height, output.length), (2, 2, 16));
        assert_eq!(
            std::slice::from_raw_parts(output.pixels, 4),
            &[255, 0, 0, 128]
        );
        fg2_image_free(&mut output);
        assert!(output.pixels.is_null());
        assert_eq!(output.length, 0);
        fg2_image_free(&mut output);
        assert_ne!(
            fg2_image_decode(std::ptr::null(), 2, &limits, &mut output),
            0
        );
        assert!(output.pixels.is_null());
        assert_ne!(
            fg2_image_decode(png.as_ptr(), usize::MAX, &limits, &mut output),
            0
        );
        assert_ne!(
            fg2_image_decode(png.as_ptr(), png.len(), std::ptr::null(), &mut output),
            0
        );
        assert_ne!(
            fg2_image_decode(png.as_ptr(), png.len(), &limits, std::ptr::null_mut()),
            0
        );
        let bad = ImageLimits {
            version: 2,
            ..limits
        };
        assert_eq!(
            fg2_image_decode(png.as_ptr(), png.len(), &bad, &mut output),
            7
        );
    }
}
