#![cfg(target_vendor = "apple")]
use zyren_runtime::{
    fg_create, fg_destroy,
    interop::{abi::*, apple::*},
};
use std::mem::size_of;

#[test]
#[ignore = "requires Metal and IOSurface"]
fn consumer_retention_bounds_frames_and_close_retires_held_storage() {
    let renderer = fg_create();
    assert_ne!(renderer, 0);
    let descriptor = Fg2SurfaceDescriptor {
        struct_size: size_of::<Fg2SurfaceDescriptor>() as u32,
        abi_version: 2,
        width: 63,
        height: 47,
        buffer_limit: 2,
        max_in_flight: 1,
        memory_limit: 1024 * 1024,
    };
    let mut surface = Fg2SurfaceSnapshot::default();
    let mut error = Fg2Error::default();
    let json = br#"{"version":1,"view_projection":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],"background":[1,0,0],"light_direction":[0,1,0],"ambient":1,"geometries":[],"meshes":[]}"#;
    unsafe {
        assert_eq!(fg2_surface_create(&descriptor, &mut surface, &mut error), 0);
        assert_eq!(
            fg2_apple_attach(renderer, surface.key, &mut surface, &mut error),
            0
        );
        let mut receipt = Fg2FrameReceipt::default();
        assert_eq!(
            fg2_apple_render(
                renderer,
                surface.key,
                1,
                1,
                json.as_ptr(),
                json.len() as u64,
                &mut receipt,
                &mut error
            ),
            0
        );
        assert_eq!(receipt.readback_bytes, 0);
        // Without a consumer, completed allocations must turn over indefinitely.
        for id in 2..20 {
            assert_eq!(
                fg2_apple_render(
                    renderer,
                    surface.key,
                    1,
                    id,
                    json.as_ptr(),
                    json.len() as u64,
                    &mut receipt,
                    &mut error
                ),
                0
            );
        }
        let held = fg2_apple_copy_pixel_buffer(surface.key);
        assert!(!held.is_null());
        assert_eq!(
            fg2_apple_render(
                renderer,
                surface.key,
                1,
                20,
                json.as_ptr(),
                json.len() as u64,
                &mut receipt,
                &mut error
            ),
            0
        );
        assert_eq!(
            fg2_apple_render(
                renderer,
                surface.key,
                1,
                21,
                json.as_ptr(),
                json.len() as u64,
                &mut receipt,
                &mut error
            ),
            6
        );
        assert_eq!(fg2_surface_close(surface.key, &mut surface, &mut error), 0);
        assert_eq!(surface.state, 3);
        assert!(fg2_apple_copy_pixel_buffer(surface.key).is_null());
        release_pixel_buffer(held);
        assert_eq!(fg2_surface_close(surface.key, &mut surface, &mut error), 0);
        assert_eq!(surface.state, 4);
    }
    assert_eq!(fg_destroy(renderer), 1);
}
