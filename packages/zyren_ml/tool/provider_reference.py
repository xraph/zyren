"""Write bounded independent Python ORT inputs/outputs for a provider probe."""
import argparse
import json
import math
from pathlib import Path

import numpy as np
import onnxruntime as ort

parser = argparse.ArgumentParser()
parser.add_argument('--manifest', required=True)
parser.add_argument('--output', required=True)
parser.add_argument('--steps', type=int, default=1000)
args = parser.parse_args()
if not 1 <= args.steps <= 4096:
    parser.error('steps must be 1..4096')
manifest_path = Path(args.manifest)
if manifest_path.stat().st_size > 65536:
    raise ValueError('Manifest exceeds byte bound')
manifest = json.loads(manifest_path.read_text())
model = manifest_path.parent / manifest['modelFile']
import hashlib
if not 0 < model.stat().st_size <= manifest['maxModelBytes'] <= 64 * 1024 * 1024:
    raise ValueError('Model exceeds byte bound')
if ort.__version__ != '1.23.2':
    raise ValueError('Reference runtime must be 1.23.2')
if hashlib.sha256(model.read_bytes()).hexdigest() != manifest['sha256']:
    raise ValueError('Model SHA differs')
options = ort.SessionOptions()
options.intra_op_num_threads = options.inter_op_num_threads = 1
session = ort.InferenceSession(str(model), options, providers=['CPUExecutionProvider'])
state = {}
output_path = Path(args.output)
# Never replace an existing receipt or frozen artifact.
with output_path.open('x') as output:
    for index in range(args.steps):
        reset = index % 100 == 0
        if reset:
            state = {}
        inputs = {}
        for spec in manifest['inputs']:
            shape = [1 if n == -1 else n for n in spec['shape']]
            if spec['dtype'] != 'float32':
                raise ValueError('Reference tool requires float32 models')
            count = math.prod(shape)
            if count > 100000:
                raise ValueError('Reference row exceeds bounded width')
            values = np.zeros(shape, dtype=np.float32)
            if spec['name'] in state:
                values[:] = state[spec['name']]
            elif spec['name'] not in manifest['recurrent']:
                values[:] = np.sin(np.arange(count) * .07 + index * .03).reshape(shape) * .1
            inputs[spec['name']] = values
        names = [spec['name'] for spec in manifest['outputs']]
        values = dict(zip(names, session.run(names, inputs), strict=True))
        def tensors(items):
            return {key: {'shape': list(value.shape), 'values': value.flatten().tolist()}
                    for key, value in items.items()}
        row = json.dumps({'reset': reset, 'inputs': tensors(inputs), 'outputs': tensors(values)},
                         allow_nan=False, separators=(',', ':'))
        if len(row.encode()) > 262144:
            raise ValueError('Reference row exceeds byte budget')
        output.write(row + '\n')
        state = {key: values[name] for key, name in manifest['recurrent'].items()}
        if output.tell() > 32 * 1024 * 1024:
            raise ValueError('Reference file exceeds byte budget')
