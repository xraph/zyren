use gpu3d_runtime::{renderer::Renderer, resources::ResourceError};
fn packet(op: u32, body: &[u8]) -> Vec<u8> {
    [
        2_u32.to_le_bytes().as_slice(),
        op.to_le_bytes().as_slice(),
        91_u64.to_le_bytes().as_slice(),
        (body.len() as u64).to_le_bytes().as_slice(),
        body,
    ]
    .concat()
}
fn descriptor(size: u64, usage: u32) -> Vec<u8> {
    [
        size.to_le_bytes().as_slice(),
        usage.to_le_bytes().as_slice(),
        0_u32.to_le_bytes().as_slice(),
    ]
    .concat()
}
fn stats(renderer: &mut Renderer) -> [u64; 3] {
    let reply = renderer.resource_command(&packet(8, &[]), 48).unwrap();
    std::array::from_fn(|i| u64::from_le_bytes(reply[24 + i * 8..32 + i * 8].try_into().unwrap()))
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn native_resource_validation_is_atomic_and_does_not_poison_device() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    assert_eq!(
        renderer.resource_command(&packet(1, &descriptor(16, 48)), 55),
        Err(ResourceError::InvalidRange)
    );
    assert_eq!(stats(&mut renderer), [0, 0, 0]);
    let reply = renderer
        .resource_command(&packet(1, &descriptor(16, 48)), 56)
        .unwrap();
    assert_eq!(&reply[8..16], &91_u64.to_le_bytes());
    let key = &reply[24..];
    for offset in [1, 16, u64::MAX - 3] {
        let body = [
            key,
            &offset.to_le_bytes(),
            &4_u64.to_le_bytes(),
            &[1, 2, 3, 4],
        ]
        .concat();
        assert_eq!(
            renderer.resource_command(&packet(2, &body), 24),
            Err(ResourceError::InvalidRange)
        );
    }
    // Failed bounds checks leave existing data and accounting unchanged.
    let read = [key, &0_u64.to_le_bytes(), &16_u64.to_le_bytes()].concat();
    assert_eq!(
        &renderer.resource_command(&packet(7, &read), 40).unwrap()[24..],
        &[0; 16]
    );
    assert_eq!(stats(&mut renderer), [16, 0, 1]);
    // Native budget applies across allocations, regardless of Dart validation.
    assert_eq!(
        renderer.resource_command(&packet(1, &descriptor(64 * 1024 * 1024, 1)), 56),
        Err(ResourceError::BudgetExceeded)
    );
    let mut foreign = key.to_vec();
    foreign[0] ^= 128;
    assert_eq!(
        renderer.resource_command(&packet(5, &foreign), 24),
        Err(ResourceError::StaleKey)
    );
    renderer.resource_command(&packet(6, key), 24).unwrap();
    assert_eq!(stats(&mut renderer), [0, 0, 0]);
    let next = renderer
        .resource_command(&packet(1, &descriptor(16, 1)), 56)
        .unwrap();
    assert_ne!(key, &next[24..]);
    assert_eq!(
        renderer.resource_command(&packet(5, key), 24),
        Err(ResourceError::StaleKey)
    );
    let invalid_usage = [
        &next[24..],
        &0_u64.to_le_bytes(),
        &4_u64.to_le_bytes(),
        &[1, 2, 3, 4],
    ]
    .concat();
    assert_eq!(
        renderer.resource_command(&packet(2, &invalid_usage), 24),
        Err(ResourceError::InvalidUsage)
    );
    renderer
        .resource_command(&packet(6, &next[24..]), 24)
        .unwrap();
    assert_eq!(stats(&mut renderer), [0, 0, 0]);
}

#[test]
fn resource_ffi_rejects_null_and_oversized_buffers() {
    use gpu3d_runtime::fg2_resource_command;
    let mut written = 99;
    let bytes = packet(8, &[]);
    let mut output = [0_u8; 48];
    unsafe {
        assert_ne!(
            fg2_resource_command(
                0,
                std::ptr::null(),
                0,
                output.as_mut_ptr(),
                48,
                &mut written
            ),
            0
        );
        assert_ne!(
            fg2_resource_command(
                0,
                bytes.as_ptr(),
                usize::MAX,
                output.as_mut_ptr(),
                48,
                &mut written
            ),
            0
        );
        assert_ne!(
            fg2_resource_command(
                0,
                bytes.as_ptr(),
                bytes.len(),
                output.as_mut_ptr(),
                48,
                &mut written
            ),
            0
        );
    }
    assert_eq!(written, 0);
}
