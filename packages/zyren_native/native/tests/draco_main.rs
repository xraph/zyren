mod support {
    pub mod draco_fixture;
}
use support::draco_fixture::encoded;
static SERIAL: std::sync::Mutex<()> = std::sync::Mutex::new(());
use zyren_runtime::draco::{MeshLimits, decode_draco};

#[test]
fn draco_ffi_owns_and_clears_packet_memory() {
    let _serial = SERIAL.lock().unwrap();
    use zyren_runtime::draco::{MeshBytes, fg2_draco_decode, fg2_draco_free};
    let bytes = encoded(10);
    let mut output = MeshBytes {
        data: std::ptr::null_mut(),
        length: 0,
    };
    unsafe {
        assert_eq!(
            fg2_draco_decode(bytes.as_ptr(), bytes.len(), &limits(), &mut output),
            0
        );
        assert!(!output.data.is_null());
        assert!(output.length > 48);
        assert_eq!(
            fg2_draco_decode(bytes.as_ptr(), bytes.len(), &limits(), &mut output),
            1
        );
        fg2_draco_free(&mut output);
        assert!(output.data.is_null());
        assert_eq!(output.length, 0);
        fg2_draco_free(&mut output);
        assert_eq!(
            fg2_draco_decode(bytes.as_ptr(), 4, &limits(), &mut output),
            1
        );
        assert!(output.data.is_null());
    }
}

fn limits() -> MeshLimits {
    MeshLimits {
        version: 1,
        max_vertices: 100,
        max_triangles: 100,
        max_attributes: 8,
        max_encoded_bytes: 1024 * 1024,
        max_decoded_bytes: 1024 * 1024,
    }
}
fn word(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

#[test]
fn draco_decodes_sequential_and_edgebreaker_with_unique_attribute_ids() {
    let _serial = SERIAL.lock().unwrap();
    for (speed, method) in [(10, 0), (0, 1)] {
        let encoded = encoded(speed);
        assert_eq!(encoded[8], method);
        let packet = decode_draco(&encoded, &limits()).unwrap();
        assert_eq!(word(&packet, 0), 4);
        assert_eq!(word(&packet, 4), 6);
        assert_eq!(word(&packet, 8), 3);
        let mut offset = 12 + 6 * 4;
        let mut ids = Vec::new();
        for _ in 0..3 {
            ids.push(word(&packet, offset));
            assert_eq!(word(&packet, offset + 4), 5); // float32
            let components = word(&packet, offset + 8);
            assert!([2, 3].contains(&components));
            let length = word(&packet, offset + 16) as usize;
            assert_eq!(length, 4 * components as usize * 4);
            offset += 20 + length;
        }
        ids.sort();
        assert_eq!(ids, [8, 21, 77]);
        assert_eq!(offset, packet.len());
    }
}

#[test]
fn draco_limits_refuse_counts_and_attribute_output() {
    let _serial = SERIAL.lock().unwrap();
    for speed in [0, 10] {
        let input = encoded(speed);
        for cap in [
            MeshLimits {
                max_vertices: 3,
                ..limits()
            },
            MeshLimits {
                max_triangles: 1,
                ..limits()
            },
            MeshLimits {
                max_decoded_bytes: 100,
                ..limits()
            },
            MeshLimits {
                max_attributes: 2,
                ..limits()
            },
        ] {
            assert_eq!(decode_draco(&input, &cap).unwrap_err(), 2);
        }
    }
}

#[test]
fn draco_rejects_truncated_input_and_huge_connectivity_before_decode() {
    let _serial = SERIAL.lock().unwrap();
    let input = encoded(10);
    for end in 0..input.len() {
        assert!(
            decode_draco(&input[..end], &limits()).is_err(),
            "accepted {end}"
        );
    }
    // Sequential 2.2 faces are a varint directly after the fixed header.
    let mut hostile = input[..11].to_vec();
    hostile.extend_from_slice(&[0xff, 0xff, 0xff, 0xff, 0x0f, 4]);
    assert_eq!(decode_draco(&hostile, &limits()).unwrap_err(), 2);
}
