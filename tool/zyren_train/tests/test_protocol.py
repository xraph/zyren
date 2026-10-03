import io
import json
import struct

import numpy as np
import pytest
from zyren_train.protocol import Frame, ProtocolError, decode, encode, read_frame


def header(**overrides):
    value = dict(version=1, operation='step', sequence=1, run_id='run',
                 environment_id='env', episode_id='episode', actor_ids=['actor'],
                 tick=1, actor_generations={'actor': 1}, payload_bytes=0, tensors=[])
    value.update(overrides)
    return value


def test_binary_tensor_roundtrip_and_partial_reads():
    value = np.array([1.5, -2, 4], dtype='<f4')
    frame = Frame.from_arrays(header(), {'action': value})
    encoded = encode(frame)
    class Partial(io.BytesIO):
        def read(self, n):
            return super().read(min(n, 2))
    decoded = read_frame(Partial(encoded))
    np.testing.assert_array_equal(decoded.array('action'), value)
    assert decoded.header['actor_ids'] == ['actor']


@pytest.mark.parametrize('data', [b'\x01', struct.pack('<I', 65537),
                                  struct.pack('<I', 4) + b'{}'])
def test_truncated_or_oversized_header(data):
    with pytest.raises(ProtocolError):
        read_frame(io.BytesIO(data))


@pytest.mark.parametrize('change', [dict(dtype='bad'), dict(shape=[-1]),
                                    dict(shape=[999999999]), dict(offset=2),
                                    dict(length=5)])
def test_tensor_layout_validation(change):
    h = header(payload_bytes=4, tensors=[dict(name='a', dtype='f32', shape=[1], offset=0, length=4)])
    h['tensors'][0].update(change)
    raw = json.dumps(h).encode()
    with pytest.raises(ProtocolError):
        decode(struct.pack('<I', len(raw)) + raw + bytes(4))


def test_unknown_version_and_message_limit():
    with pytest.raises(ProtocolError):
        encode(Frame(header(version=2), b''))
    with pytest.raises(ProtocolError):
        encode(Frame(header(payload_bytes=16 * 1024 * 1024), bytes(1)))


def test_depth_and_metadata_budgets_are_typed_errors():
    nested = 0
    for _ in range(1000):
        nested = [nested]
    with pytest.raises(ProtocolError):
        encode(Frame(header(nested=nested), b''))
    raw = b'{"nested":' + b'[' * 1000 + b'0' + b']' * 1000 + b'}'
    with pytest.raises(ProtocolError):
        decode(struct.pack('<I', len(raw)) + raw)
    with pytest.raises(ProtocolError):
        encode(Frame(header(extra='x' * 65537), b''))
