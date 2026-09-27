#![cfg(target_vendor = "apple")]
use gpu3d_runtime::{renderer::Renderer, scene::Frame};
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
    use gpu3d_runtime::{
        fg_create, fg_destroy, fg_render,
        interop::metal::{fg_metal_copy_device, fg_metal_readback_bytes},
    };
    use objc2::{rc::Retained, runtime::ProtocolObject};
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
