use zyren_runtime::resources::upload::{Command, checked_upload_range};

fn packet(op: u32, body: &[u8]) -> Vec<u8> {
    let mut data = Vec::new();
    data.extend(2_u32.to_le_bytes());
    data.extend(op.to_le_bytes());
    data.extend(17_u64.to_le_bytes());
    data.extend((body.len() as u64).to_le_bytes());
    data.extend(body);
    data
}

#[test]
fn overflowing_upload_range_is_rejected() {
    assert!(checked_upload_range(u64::MAX - 3, 8, 1024).is_err());
    assert_eq!(checked_upload_range(12, 16, 64).unwrap(), 12..28);
}

#[test]
fn framing_and_descriptors_fail_before_native_allocation() {
    let valid = packet(8, &[]);
    assert!(Command::decode(&valid).is_ok());
    for end in 0..valid.len() {
        assert!(Command::decode(&valid[..end]).is_err());
    }
    for bad in [
        packet(999, &[]),
        packet(8, &[0]),
        {
            let mut data = valid.clone();
            data[0] = 1;
            data
        },
        {
            let mut data = valid.clone();
            data[16..24].copy_from_slice(&u64::MAX.to_le_bytes());
            data
        },
    ] {
        assert!(Command::decode(&bad).is_err());
    }
    let mut body = Vec::new();
    body.extend(16_u64.to_le_bytes());
    body.extend(0_u32.to_le_bytes()); // empty usage
    body.extend(0_u32.to_le_bytes()); // label length
    assert!(Command::decode(&packet(1, &body)).is_err());
}

#[test]
fn bounded_random_packets_never_panic() {
    let mut seed = 0x9182_73ab_u64;
    for len in 0..2048 {
        let bytes: Vec<_> = (0..len)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 7;
                seed ^= seed << 17;
                seed as u8
            })
            .collect();
        let _ = Command::decode(&bytes);
        let _ = Command::decode(&packet((len % 10) as u32, &bytes));
    }
}

#[test]
fn valid_operations_reject_every_truncation_and_trailing_bytes() {
    let key: Vec<u8> = [1_u64, 1, 0, 1]
        .into_iter()
        .flat_map(u64::to_le_bytes)
        .collect();
    let mut buffer = Vec::new();
    buffer.extend(64_u64.to_le_bytes());
    buffer.extend(63_u32.to_le_bytes());
    buffer.extend(4_u32.to_le_bytes());
    buffer.extend(b"mesh");
    let mut texture: Vec<u8> = [3_u32, 5, 3, 1, 15, 3]
        .into_iter()
        .flat_map(u32::to_le_bytes)
        .collect();
    texture.extend(b"sky");
    let mut write_buffer = key.clone();
    write_buffer.extend(0_u64.to_le_bytes());
    write_buffer.extend(4_u64.to_le_bytes());
    write_buffer.extend([0; 4]);
    let mut write_texture = key.clone();
    write_texture.extend(0_u32.to_le_bytes());
    write_texture.extend(4_u64.to_le_bytes());
    write_texture.extend([0; 4]);
    let mut read = key.clone();
    read.extend(0_u64.to_le_bytes());
    read.extend(4_u64.to_le_bytes());
    let mut read_texture = key.clone();
    read_texture.extend(0_u32.to_le_bytes());
    for (op, body) in [
        (1, buffer),
        (2, write_buffer),
        (3, texture),
        (4, write_texture),
        (5, key.clone()),
        (6, key),
        (7, read),
        (8, vec![]),
        (9, read_texture),
    ] {
        let valid = packet(op, &body);
        assert!(Command::decode(&valid).is_ok(), "opcode {op}");
        for end in 0..valid.len() {
            assert!(
                Command::decode(&valid[..end]).is_err(),
                "opcode {op}, end {end}"
            );
        }
        let mut trailing = body;
        trailing.push(0);
        assert!(Command::decode(&packet(op, &trailing)).is_err());
    }
}

#[test]
fn compressed_descriptors_count_blocks_and_reject_non_sampled_usage() {
    use zyren_runtime::resources::upload::Operation;
    for format in 3..=8 {
        let descriptor = |width: u32, usage: u32| {
            packet(
                3,
                &[width, 8, 4, format, usage, 0]
                    .into_iter()
                    .flat_map(u32::to_le_bytes)
                    .collect::<Vec<_>>(),
            )
        };
        let valid = descriptor(12, 13);
        let Operation::CreateTexture(d) = Command::decode(&valid).unwrap().operation else {
            panic!()
        };
        assert_eq!(d.byte_length(), 160);
        assert!(Command::decode(&descriptor(5, 13)).is_err());
        assert!(Command::decode(&descriptor(12, 15)).is_err());
        assert!(Command::decode(&descriptor(12, 29)).is_err());
    }
    assert!(Command::decode(&packet(11, &[])).is_ok());
    assert!(Command::decode(&packet(11, &[0])).is_err());
}
