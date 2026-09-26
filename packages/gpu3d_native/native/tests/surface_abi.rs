use flutter_gpu3d::interop::abi::*;
use std::mem::size_of;

fn error() -> Fg2Error {
    Fg2Error::default()
}
fn descriptor() -> Fg2SurfaceDescriptor {
    Fg2SurfaceDescriptor {
        struct_size: size_of::<Fg2SurfaceDescriptor>() as u32,
        abi_version: 2,
        width: 64,
        height: 47,
        buffer_limit: 3,
        max_in_flight: 2,
        memory_limit: 1024 * 1024,
    }
}
#[test]
fn validates_version_runtime_generation_and_epoch() {
    let mut result = Fg2SurfaceSnapshot::default();
    let mut issue = error();
    let mut desc = descriptor();
    unsafe {
        desc.abi_version = 99;
        assert_ne!(fg2_surface_create(&desc, &mut result, &mut issue), 0);
        assert!(issue.message_length > 0);
        desc.abi_version = 2;
        assert_eq!(fg2_surface_create(&desc, &mut result, &mut issue), 0);
        assert_eq!(result.key.runtime_token, fg2_runtime_token());
        let original = result;
        let mut wrong = result.key;
        wrong.runtime_token ^= 1;
        assert_ne!(
            fg2_surface_resize(wrong, result.epoch, 70, 50, &mut result, &mut issue),
            0
        );
        assert_eq!(
            fg2_surface_resize(
                original.key,
                original.epoch,
                70,
                50,
                &mut result,
                &mut issue
            ),
            0
        );
        assert_eq!(result.epoch, 2);
        assert_ne!(
            fg2_surface_resize(
                original.key,
                original.epoch,
                80,
                50,
                &mut result,
                &mut issue
            ),
            0
        );
        assert_eq!(fg2_surface_close(original.key, &mut result, &mut issue), 0);
        assert_eq!(fg2_surface_close(original.key, &mut result, &mut issue), 0);
    }
}
#[test]
fn errors_are_request_owned_and_short_output_is_not_overwritten() {
    unsafe {
        let desc = descriptor();
        let mut output = Fg2SurfaceSnapshot {
            struct_size: 8,
            ..Default::default()
        };
        let mut first = error();
        let mut second = error();
        assert_ne!(fg2_surface_create(&desc, &mut output, &mut first), 0);
        let saved = first.message;
        assert_ne!(
            fg2_surface_create(std::ptr::null(), &mut output, &mut second),
            0
        );
        assert_eq!(first.message, saved);
        assert_eq!(output.struct_size, 8);
        assert_eq!(output.epoch, 0);
    }
}
