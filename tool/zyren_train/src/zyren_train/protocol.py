"""Wire v1: bounded JSON metadata followed by little-endian tensor blocks."""
from dataclasses import dataclass
import io
import json
import struct

import numpy as np

MAX_HEADER = 65536
MAX_MESSAGE = 16 * 1024 * 1024
DTYPES = {'f32': np.dtype('<f4'), 'f64': np.dtype('<f8'),
          'i32': np.dtype('<i4'), 'u8': np.dtype('u1')}


class ProtocolError(RuntimeError):
    pass


def _integer(value, minimum=0, maximum=MAX_MESSAGE):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ProtocolError('invalid integer bound')
    return value


def _identifier(value):
    if not isinstance(value, str) or not 1 <= len(value.encode('utf-8')) <= 256:
        raise ProtocolError('invalid identity')
    return value


def _metadata_bounds(value):
    pending, nodes = [(value, 0)], 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        if depth > 64 or nodes > 8192:
            raise ProtocolError('metadata depth or node budget exceeded')
        if isinstance(current, dict):
            if len(current) > 8192 or any(not isinstance(k, str) for k in current):
                raise ProtocolError('invalid metadata map')
            pending.extend((v, depth + 1) for pair in current.items() for v in pair)
        elif isinstance(current, list):
            if len(current) > 8192:
                raise ProtocolError('metadata list exceeds budget')
            pending.extend((v, depth + 1) for v in current)
        elif isinstance(current, str) and len(current.encode('utf-8')) > MAX_HEADER:
            raise ProtocolError('metadata string exceeds budget')
        elif current is not None and not isinstance(current, (str, int, float, bool)):
            raise ProtocolError('unsupported metadata type')


def _check_json_depth(data):
    depth, quoted, escaped = 0, False, False
    for byte in data:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            if depth > 64:
                raise ProtocolError('metadata nesting exceeds budget')
        elif byte in (93, 125):
            depth -= 1

def validate(header, *, max_message=MAX_MESSAGE):
    _metadata_bounds(header)
    if not isinstance(header, dict) or type(header.get('version')) is not int or header.get('version') != 1:
        raise ProtocolError('unsupported wire version')
    _integer(header.get('sequence'), maximum=2**53 - 1)
    _integer(header.get('tick'), maximum=2**53 - 1)
    for key in ('run_id', 'environment_id', 'episode_id'):
        _identifier(header.get(key))
    if header.get('operation') not in ('hello', 'reset', 'step', 'snapshot', 'restore', 'close'):
        raise ProtocolError('unsupported operation')
    actors = header.get('actor_ids')
    if not isinstance(actors, list) or len(actors) > 256:
        raise ProtocolError('invalid actors')
    for actor in actors:
        _identifier(actor)
    if len(set(actors)) != len(actors):
        raise ProtocolError('duplicate actors')
    generations = header.get('actor_generations')
    if not isinstance(generations, dict) or set(generations) != set(actors):
        raise ProtocolError('actor generation identity differs')
    for generation in generations.values():
        _integer(generation, minimum=1, maximum=2**53 - 1)

    payload = _integer(header.get('payload_bytes'), maximum=max_message)
    tensors = header.get('tensors')
    if not isinstance(tensors, list) or len(tensors) > 256:
        raise ProtocolError('invalid tensors')
    names, ranges = set(), []
    for tensor in tensors:
        if not isinstance(tensor, dict):
            raise ProtocolError('invalid tensor descriptor')
        name = _identifier(tensor.get('name'))
        if name in names or tensor.get('dtype') not in DTYPES:
            raise ProtocolError('duplicate tensor or invalid dtype')
        names.add(name)
        shape = tensor.get('shape')
        if not isinstance(shape, list) or not 1 <= len(shape) <= 8:
            raise ProtocolError('invalid tensor shape')
        count = 1
        for dim in shape:
            count *= _integer(dim, minimum=1)
            if count > max_message:
                raise ProtocolError('tensor shape exceeds limit')
        offset = _integer(tensor.get('offset'))
        length = _integer(tensor.get('length'))
        if length != count * DTYPES[tensor['dtype']].itemsize or offset + length > payload:
            raise ProtocolError('tensor layout differs from shape')
        if any(offset < end and start < offset + length for start, end in ranges):
            raise ProtocolError('overlapping tensor blocks')
        ranges.append((offset, offset + length))
    if sum(end - start for start, end in ranges) != payload:
        raise ProtocolError('unclaimed tensor payload')
    return payload


@dataclass(frozen=True)
class Frame:
    header: dict
    payload: bytes

    @classmethod
    def from_arrays(cls, header, arrays):
        blocks, descriptors, offset = [], [], 0
        for name, array in arrays.items():
            array = np.asarray(array)
            dtype = next((key for key, value in DTYPES.items()
                          if value.kind == array.dtype.kind and value.itemsize == array.dtype.itemsize), None)
            if dtype is None:
                raise ProtocolError('unsupported array dtype')
            if array.nbytes + offset > MAX_MESSAGE:
                raise ProtocolError('tensor payload exceeds limit')
            block = np.ascontiguousarray(array, dtype=DTYPES[dtype]).tobytes()
            descriptors.append(dict(name=name, dtype=dtype, shape=list(array.shape),
                                    offset=offset, length=len(block)))
            offset += len(block)
            if offset > MAX_MESSAGE:
                raise ProtocolError('tensor payload exceeds limit')
            blocks.append(block)
        metadata = dict(header, tensors=descriptors, payload_bytes=offset)
        validate(metadata)
        return cls(metadata, b''.join(blocks))

    def array(self, name):
        validate(self.header)
        if len(self.payload) != self.header['payload_bytes']:
            raise ProtocolError('truncated payload')
        for tensor in self.header['tensors']:
            if tensor['name'] == name:
                return np.frombuffer(self.payload, dtype=DTYPES[tensor['dtype']],
                                     count=tensor['length'] // DTYPES[tensor['dtype']].itemsize,
                                     offset=tensor['offset']).reshape(tensor['shape']).copy()
        raise ProtocolError('tensor is missing')


def encode(frame, *, max_header=MAX_HEADER, max_message=MAX_MESSAGE):
    size = validate(frame.header, max_message=max_message)
    header = json.dumps(frame.header, separators=(',', ':'), allow_nan=False).encode('utf-8')
    if not 0 < len(header) <= max_header or 4 + len(header) + size > max_message:
        raise ProtocolError('message exceeds negotiated bounds')
    if len(frame.payload) != size:
        raise ProtocolError('payload length differs')
    return struct.pack('<I', len(header)) + header + frame.payload


def _read_exact(stream, count):
    chunks, received = [], 0
    while received < count:
        chunk = stream.read(count - received)
        if not chunk:
            raise ProtocolError('truncated frame or worker closed')
        chunks.append(chunk)
        received += len(chunk)
    return b''.join(chunks)


def read_frame(stream, *, max_header=MAX_HEADER, max_message=MAX_MESSAGE):
    length = struct.unpack('<I', _read_exact(stream, 4))[0]
    if not 0 < length <= max_header or 4 + length > max_message:
        raise ProtocolError('header exceeds negotiated bounds')
    try:
        raw = _read_exact(stream, length)
        _check_json_depth(raw)
        header = json.loads(raw)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise ProtocolError('invalid metadata') from error
    size = validate(header, max_message=max_message)
    if 4 + length + size > max_message:
        raise ProtocolError('message exceeds negotiated bounds')
    return Frame(header, _read_exact(stream, size))


def decode(data, **limits):
    stream = io.BytesIO(data)
    frame = read_frame(stream, **limits)
    if stream.read(1):
        raise ProtocolError('trailing bytes')
    return frame
