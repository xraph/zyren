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

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn storage_texture_admission_rejects_srgb_without_poisoning_device() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    let descriptor = |format: u32| {
        [4_u32, 4, 1, format, 29, 0]
            .into_iter()
            .flat_map(u32::to_le_bytes)
            .collect::<Vec<_>>()
    };
    assert_eq!(
        renderer.resource_command(&packet(3, &descriptor(1)), 56),
        Err(ResourceError::InvalidUsage)
    );
    let texture = renderer
        .resource_command(&packet(3, &descriptor(0)), 56)
        .unwrap();
    let bytes = [texture[24..].to_vec(), 0_u32.to_le_bytes().to_vec()].concat();
    let pixels = renderer.resource_command(&packet(9, &bytes), 88).unwrap();
    assert_eq!(&pixels[24..], &[0; 64]);
    renderer
        .resource_command(&packet(6, &texture[24..]), 24)
        .unwrap();
    assert_eq!(stats(&mut renderer), [0, 0, 0]);
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
    // The resident allowance is separate from the per-allocation limit.
    let mut large = Vec::new();
    for _ in 0..3 {
        let reply = renderer
            .resource_command(&packet(1, &descriptor(64 * 1024 * 1024, 1)), 56)
            .unwrap();
        large.push(reply[24..].to_vec());
    }
    // Native budget applies across allocations, regardless of Dart validation.
    assert_eq!(
        renderer.resource_command(&packet(1, &descriptor(64 * 1024 * 1024, 1)), 56),
        Err(ResourceError::BudgetExceeded)
    );
    for allocation in large {
        renderer
            .resource_command(&packet(6, &allocation), 24)
            .unwrap();
    }
    assert_eq!(stats(&mut renderer), [16, 0, 1]);
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

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn mip_generation_rejects_invalid_usage_policy_and_keys_without_mutation() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    for usage in [1_u32, 2, 3] {
        let descriptor: Vec<u8> = [2_u32, 2, 2, 0, usage, 0]
            .into_iter()
            .flat_map(u32::to_le_bytes)
            .collect();
        let reply = renderer
            .resource_command(&packet(3, &descriptor), 56)
            .unwrap();
        let key = &reply[24..];
        let body = [key, &0_u32.to_le_bytes()].concat();
        assert_eq!(
            renderer.resource_command(&packet(10, &body), 23),
            Err(ResourceError::InvalidRange)
        );
        let invalid = [key, &2_u32.to_le_bytes()].concat();
        assert_eq!(
            renderer.resource_command(&packet(10, &invalid), 24),
            Err(ResourceError::InvalidCommand)
        );
        if usage == 3 {
            renderer.resource_command(&packet(10, &body), 24).unwrap();
        } else {
            assert_eq!(
                renderer.resource_command(&packet(10, &body), 24),
                Err(ResourceError::InvalidUsage)
            );
        }
        assert_eq!(stats(&mut renderer), [20, 0, 1]);
        renderer.resource_command(&packet(6, key), 24).unwrap();
        assert_eq!(stats(&mut renderer), [0, 0, 0]);
        assert_eq!(
            renderer.resource_command(&packet(10, &body), 24),
            Err(ResourceError::StaleKey)
        );
    }
}

#[test]
fn mip_command_checks_every_field_and_truncation() {
    use gpu3d_runtime::resources::upload::Command;
    let body = [vec![0_u8; 32], 1_u32.to_le_bytes().to_vec()].concat();
    let valid = packet(10, &body);
    assert!(Command::decode(&valid).is_ok());
    for end in 0..valid.len() {
        let mut truncated = valid[..end].to_vec();
        if end >= 24 {
            truncated[16..24].copy_from_slice(&((end - 24) as u64).to_le_bytes());
        }
        assert!(Command::decode(&truncated).is_err());
    }
    let mut invalid = body.clone();
    invalid[32..36].copy_from_slice(&2_u32.to_le_bytes());
    assert!(matches!(
        Command::decode(&packet(10, &invalid)),
        Err(ResourceError::InvalidCommand)
    ));
    let mut trailing = body;
    trailing.push(0);
    assert!(Command::decode(&packet(10, &trailing)).is_err());
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn compressed_format_admission_is_atomic_and_checks_query_capacity() {
    let mut renderer = pollster::block_on(Renderer::new()).unwrap();
    assert_eq!(
        renderer.resource_command(&packet(11, &[]), 27),
        Err(ResourceError::InvalidRange)
    );
    let reply = renderer.resource_command(&packet(11, &[]), 28).unwrap();
    let mask = u32::from_le_bytes(reply[24..28].try_into().unwrap());
    assert_eq!(mask & 7, 7);
    for format in 3..=8 {
        let body: Vec<u8> = [8_u32, 8, 4, format, 13, 0]
            .into_iter()
            .flat_map(u32::to_le_bytes)
            .collect();
        let reply = renderer.resource_command(&packet(3, &body), 56);
        if mask & (1 << format) == 0 {
            assert_eq!(reply, Err(ResourceError::InvalidUsage));
        } else {
            let reply = reply.unwrap();
            assert_eq!(stats(&mut renderer), [112, 0, 1]);
            let key = &reply[24..];
            let bad: Vec<u8> = [key, &2_u32.to_le_bytes(), &4_u64.to_le_bytes(), &[0; 4]].concat();
            assert_eq!(
                renderer.resource_command(&packet(4, &bad), 24),
                Err(ResourceError::InvalidRange)
            );
            let generate = [key, &0_u32.to_le_bytes()].concat();
            assert_eq!(
                renderer.resource_command(&packet(10, &generate), 24),
                Err(ResourceError::InvalidUsage)
            );
            renderer.resource_command(&packet(6, key), 24).unwrap();
        }
        assert_eq!(stats(&mut renderer), [0, 0, 0]);
    }
}

#[test]
#[ignore = "requires a native Metal, Vulkan or DX12 device"]
fn a_device_without_enabled_compression_rejects_blocks_before_allocation() {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::METAL | wgpu::Backends::VULKAN | wgpu::Backends::DX12,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapter = pollster::block_on(instance.request_adapter(&Default::default())).unwrap();
    let (device, queue) = pollster::block_on(adapter.request_device(&Default::default())).unwrap();
    let mut store = gpu3d_runtime::resources::ResourceStore::default();
    let query = store
        .execute(&device, &queue, &packet(11, &[]), 28)
        .unwrap();
    assert_eq!(&query[24..28], &7_u32.to_le_bytes());
    for format in 3..=8 {
        let body: Vec<u8> = [8_u32, 8, 4, format, 13, 0]
            .into_iter()
            .flat_map(u32::to_le_bytes)
            .collect();
        assert_eq!(
            store.execute(&device, &queue, &packet(3, &body), 56),
            Err(ResourceError::InvalidUsage)
        );
    }
    let stats = store.execute(&device, &queue, &packet(8, &[]), 48).unwrap();
    assert_eq!(&stats[24..], &[0; 24]);
    let body: Vec<u8> = [8_u32, 8, 4, 1, 13, 0]
        .into_iter()
        .flat_map(u32::to_le_bytes)
        .collect();
    let key = store
        .execute(&device, &queue, &packet(3, &body), 56)
        .unwrap();
    store
        .execute(&device, &queue, &packet(6, &key[24..]), 24)
        .unwrap();
}
