#![cfg(target_vendor = "apple")]
use objc2_core_foundation::{CFDictionary, CFNumber};
use objc2_io_surface::{
    IOSurfaceRef, kIOSurfaceBytesPerElement, kIOSurfaceBytesPerRow, kIOSurfaceHeight,
    kIOSurfacePixelFormat, kIOSurfaceWidth,
};
use objc2_metal::{
    MTLDevice, MTLOrigin, MTLPixelFormat, MTLRegion, MTLSize, MTLStorageMode, MTLTexture,
    MTLTextureDescriptor, MTLTextureUsage,
};
use serde_json::json;
use zyren_runtime::{renderer::Renderer, scene::Frame};

#[test]
#[ignore = "requires a native Metal device"]
fn renders_into_consumer_texture_without_readback() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let device = renderer.metal_device().unwrap();
    let descriptor = MTLTextureDescriptor::new();
    unsafe {
        descriptor.setWidth(63);
        descriptor.setHeight(47);
    }
    descriptor.setPixelFormat(MTLPixelFormat::BGRA8Unorm_sRGB);
    descriptor.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
    descriptor.setStorageMode(MTLStorageMode::Shared);
    let properties = unsafe {
        CFDictionary::from_slices(
            &[
                kIOSurfaceWidth,
                kIOSurfaceHeight,
                kIOSurfaceBytesPerElement,
                kIOSurfaceBytesPerRow,
                kIOSurfacePixelFormat,
            ],
            &[
                &*CFNumber::new_i32(63),
                &*CFNumber::new_i32(47),
                &*CFNumber::new_i32(4),
                &*CFNumber::new_i32(256),
                &*CFNumber::new_i32(i32::from_be_bytes(*b"BGRA")),
            ],
        )
    };
    let surface = unsafe { IOSurfaceRef::new(properties.as_opaque()) }.unwrap();
    let texture = device
        .newTextureWithDescriptor_iosurface_plane(&descriptor, &surface, 0)
        .unwrap();
    drop(surface);
    let identity = glam::Mat4::IDENTITY.to_cols_array();
    let mut frame: Frame = serde_json::from_value(json!({
        "version":1, "view_projection":identity, "background":[0,0,1],
        "light_direction":[0,0,1], "ambient":0.2,
        "geometries":[{"id":1,"positions":[[-0.8,-0.8,0.4],[0.8,-0.8,0.4],[0,0.8,0.4]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":identity,"color":[1,0,0],"unlit":true}]
    }))
    .unwrap();
    unsafe { renderer.render_to_metal(&frame, texture.clone()) }.unwrap();
    assert_eq!(renderer.counters().submitted_frames, 1);
    assert_eq!(renderer.counters().readback_bytes, 0);
    // Test-only capture after producer completion, outside presentation counters.
    let mut pixels = vec![0u8; 63 * 47 * 4];
    unsafe {
        texture.getBytes_bytesPerRow_fromRegion_mipmapLevel(
            std::ptr::NonNull::new(pixels.as_mut_ptr().cast()).unwrap(),
            63 * 4,
            MTLRegion {
                origin: MTLOrigin { x: 0, y: 0, z: 0 },
                size: MTLSize {
                    width: 63,
                    height: 47,
                    depth: 1,
                },
            },
            0,
        );
    }
    assert_eq!(&pixels[..4], &[255, 0, 0, 255]);
    let center = (23 * 63 + 31) * 4;
    assert_eq!(&pixels[center..center + 4], &[0, 0, 255, 255]);
    descriptor.setPixelFormat(MTLPixelFormat::RGBA8Unorm);
    let wrong_format = device.newTextureWithDescriptor(&descriptor).unwrap();
    assert!(unsafe { renderer.render_to_metal(&frame, wrong_format) }.is_err());
    assert_eq!(renderer.counters().submitted_frames, 1);
    frame.geometries.clear();
    let readback = renderer.render(&frame, 63, 47).unwrap();
    assert_eq!(&readback[center..center + 4], &[255, 0, 0, 255]);
    assert_eq!(renderer.counters().readback_bytes, 11844);
}

#[test]
#[ignore = "requires a native Metal device"]
fn adapter_counter_observes_actual_renderer_readback() {
    use objc2::{rc::Retained, runtime::ProtocolObject};
    use zyren_runtime::{
        fg_create, fg_destroy, fg_render,
        interop::metal::{fg_metal_copy_device, fg_metal_readback_bytes},
    };
    let handle = fg_create();
    assert_ne!(handle, 0);
    let device = unsafe {
        Retained::from_raw(fg_metal_copy_device(handle).cast::<ProtocolObject<dyn MTLDevice>>())
    }
    .unwrap();
    assert!(fg_metal_copy_device(u64::MAX).is_null());
    assert_eq!(fg_metal_readback_bytes(handle), 0);
    let frame = serde_json::to_vec(&json!({
        "version": 1, "view_projection": glam::Mat4::IDENTITY.to_cols_array(),
        "background": [1, 0, 0], "light_direction": [0, 0, 1], "ambient": 1,
        "geometries": [], "meshes": []
    }))
    .unwrap();
    let mut pixels = vec![0; 16 * 8 * 4];
    assert_eq!(
        unsafe {
            fg_render(
                handle,
                frame.as_ptr(),
                frame.len(),
                16,
                8,
                pixels.as_mut_ptr(),
                pixels.len(),
            )
        },
        1
    );
    assert_eq!(&pixels[..4], &[255, 0, 0, 255]);
    assert_eq!(fg_metal_readback_bytes(handle), 512);
    assert_eq!(fg_destroy(handle), 1);
    drop(device);
}

#[test]
#[ignore = "requires a native Metal device"]
fn native_surface_premultiplies_encoded_color_and_capture_stays_straight() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let device = renderer.metal_device().unwrap();
    let descriptor = MTLTextureDescriptor::new();
    unsafe {
        descriptor.setWidth(8);
        descriptor.setHeight(8);
    }
    descriptor.setPixelFormat(MTLPixelFormat::BGRA8Unorm_sRGB);
    descriptor.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
    descriptor.setStorageMode(MTLStorageMode::Shared);
    let texture = device.newTextureWithDescriptor(&descriptor).unwrap();
    let mut frame: Frame = serde_json::from_value(json!({
        "version":1, "view_projection":glam::Mat4::IDENTITY.to_cols_array(),
        "background":[0.25,0.5,0.75], "background_alpha":0.5,
        "light_direction":[0,0,1], "ambient":1,
        "geometries":[], "meshes":[]
    }))
    .unwrap();
    for (alpha, expected) in [
        (0.5, [113, 94, 69, 128]),
        (0., [0, 0, 0, 0]),
        (1., [225, 188, 137, 255]),
        (0.5, [113, 94, 69, 128]),
    ] {
        frame.background_alpha = alpha;
        unsafe { renderer.render_to_metal(&frame, texture.clone()) }.unwrap();
        let mut pixels = [0_u8; 8 * 8 * 4];
        unsafe {
            texture.getBytes_bytesPerRow_fromRegion_mipmapLevel(
                std::ptr::NonNull::new(pixels.as_mut_ptr().cast()).unwrap(),
                8 * 4,
                MTLRegion {
                    origin: MTLOrigin { x: 0, y: 0, z: 0 },
                    size: MTLSize {
                        width: 8,
                        height: 8,
                        depth: 1,
                    },
                },
                0,
            );
        }
        for (actual, expected) in pixels[..4].iter().zip(expected) {
            assert!((i32::from(*actual) - expected).abs() <= 2, "{pixels:?}");
        }
    }
    assert_eq!(renderer.counters().readback_bytes, 0);
    let straight = renderer.render(&frame, 8, 8).unwrap();
    for (actual, expected) in straight[..4].iter().zip([137, 188, 225, 128]) {
        assert!((i32::from(*actual) - expected).abs() <= 2);
    }
}

#[test]
#[ignore = "requires a native Metal device"]
fn initialized_depth_occludes_opaque_and_blended_geometry() {
    use objc2_metal::{
        MTLCommandBuffer, MTLCommandEncoder, MTLCommandQueue, MTLLoadAction,
        MTLRenderPassDescriptor, MTLStoreAction,
    };
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let device = renderer.metal_device().unwrap();
    let queue = device.newCommandQueue().unwrap();
    let descriptor = MTLTextureDescriptor::new();
    unsafe {
        descriptor.setWidth(16);
        descriptor.setHeight(16);
    }
    descriptor.setPixelFormat(MTLPixelFormat::BGRA8Unorm_sRGB);
    descriptor.setUsage(MTLTextureUsage::RenderTarget | MTLTextureUsage::ShaderRead);
    descriptor.setStorageMode(MTLStorageMode::Shared);
    let color = device.newTextureWithDescriptor(&descriptor).unwrap();
    descriptor.setPixelFormat(MTLPixelFormat::Depth32Float);
    descriptor.setStorageMode(MTLStorageMode::Private);
    let depth = device.newTextureWithDescriptor(&descriptor).unwrap();
    let initialize = |value: f64| {
        let pass = MTLRenderPassDescriptor::new();
        let attachment = pass.depthAttachment();
        attachment.setTexture(Some(&depth));
        attachment.setLoadAction(MTLLoadAction::Clear);
        attachment.setStoreAction(MTLStoreAction::Store);
        attachment.setClearDepth(value);
        let command = queue.commandBuffer().unwrap();
        let encoder = command.renderCommandEncoderWithDescriptor(&pass).unwrap();
        encoder.endEncoding();
        command.commit();
        command.waitUntilCompleted();
        assert_eq!(
            command.status(),
            objc2_metal::MTLCommandBufferStatus::Completed
        );
        assert!(command.error().is_none());
    };
    let pixel = || {
        let mut pixels = [0u8; 16 * 16 * 4];
        unsafe {
            color.getBytes_bytesPerRow_fromRegion_mipmapLevel(
                std::ptr::NonNull::new(pixels.as_mut_ptr().cast()).unwrap(),
                64,
                MTLRegion {
                    origin: MTLOrigin { x: 0, y: 0, z: 0 },
                    size: MTLSize {
                        width: 16,
                        height: 16,
                        depth: 1,
                    },
                },
                0,
            );
        }
        pixels[(8 * 16 + 8) * 4..(8 * 16 + 8) * 4 + 4].to_vec()
    };
    let identity = glam::Mat4::IDENTITY.to_cols_array();
    let mut frame: Frame = serde_json::from_value(json!({
        "version":1, "view_projection":identity, "background":[0,0,0],
        "background_alpha":0, "light_direction":[0,0,1], "ambient":1,
        "geometries":[{"id":1,"positions":[[-1,-1,0.4],[1,-1,0.4],[0,1,0.4]],
            "normals":[[0,0,1],[0,0,1],[0,0,1]],"indices":[0,1,2]}],
        "meshes":[{"geometry":1,"model":identity,"color":[1,0,0],"unlit":true}]
    }))
    .unwrap();
    for alpha in [1., 0.5] {
        frame.meshes[0].opacity = alpha;
        frame.meshes[0].alpha_mode = if alpha < 1. { 2 } else { 0 };
        for (prefill, visible) in [(0.2, false), (0.8, true), (0.2, false)] {
            initialize(prefill);
            unsafe {
                renderer.render_to_metal_with_depth(&frame, color.clone(), Some(depth.clone()))
            }
            .unwrap();
            frame.geometries.clear();
            let value = pixel();
            if visible {
                assert!(value[2] > 100 && value[3] > 100, "{value:?}");
            } else {
                assert_eq!(value, [0, 0, 0, 0]);
            }
        }
    }
    // The ordinary entry point must clear its own depth after imported frames.
    unsafe { renderer.render_to_metal(&frame, color.clone()) }.unwrap();
    assert!(pixel()[2] > 100);
    frame.settings.depth_strategy = 1;
    frame.meshes[0].reversed_depth = true;
    for (prefill, visible) in [(0.2, true), (0.8, false)] {
        initialize(prefill);
        unsafe { renderer.render_to_metal_with_depth(&frame, color.clone(), Some(depth.clone())) }
            .unwrap();
        assert_eq!(pixel()[2] > 100, visible);
    }
    let submitted = renderer.counters().submitted_frames;
    descriptor.setPixelFormat(MTLPixelFormat::RGBA8Unorm);
    let invalid = device.newTextureWithDescriptor(&descriptor).unwrap();
    assert!(
        unsafe { renderer.render_to_metal_with_depth(&frame, color.clone(), Some(invalid)) }
            .is_err()
    );
    frame.settings.enabled = true;
    assert!(
        unsafe { renderer.render_to_metal_with_depth(&frame, color.clone(), Some(depth.clone())) }
            .is_err()
    );
    assert_eq!(renderer.counters().submitted_frames, submitted);
    assert_eq!(renderer.counters().readback_bytes, 0);
}
