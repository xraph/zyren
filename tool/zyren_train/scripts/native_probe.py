"""Check the exported fixtures against the actual Zyren C ABI."""
from __future__ import annotations
import argparse
import ctypes as c
import json
from pathlib import Path
import numpy as np


class Tensor(c.Structure):
    _fields_ = [("dtype", c.c_int32), ("rank", c.c_int32),
                ("dimensions", c.POINTER(c.c_int64)), ("byte_length", c.c_size_t),
                ("data", c.c_void_p)]


def probe(bridge_path: Path, runtime_path: Path, fixtures: Path) -> dict:
    runtime = c.CDLL(str(runtime_path.resolve()))
    runtime.OrtGetApiBase.restype = c.c_void_p
    bridge = c.CDLL(str(bridge_path.resolve()))
    bridge.zyren_ml_open.argtypes = [c.c_void_p, c.c_void_p, c.c_size_t,
                                    c.POINTER(c.c_void_p), c.c_void_p, c.c_size_t]
    bridge.zyren_ml_run.argtypes = [c.c_void_p, c.POINTER(c.c_char_p), c.POINTER(Tensor),
                                   c.c_size_t, c.POINTER(c.c_char_p), c.c_size_t,
                                   c.POINTER(c.c_void_p), c.c_void_p, c.c_size_t]
    bridge.zyren_ml_result_tensor.argtypes = [c.c_void_p, c.c_size_t,
                                             c.POINTER(Tensor), c.c_void_p, c.c_size_t]
    bridge.zyren_ml_result_close.argtypes = [c.c_void_p]
    bridge.zyren_ml_close.argtypes = [c.c_void_p]
    bridge.zyren_ml_live_sessions.restype = c.c_int64
    bridge.zyren_ml_live_results.restype = c.c_int64
    error = c.create_string_buffer(2048)
    receipts = []
    for name in ("linear", "lstm_step", "cnn_step"):
        model = c.create_string_buffer((fixtures / f"{name}.onnx").read_bytes())
        values = json.loads((fixtures / f"{name}.values.json").read_text())
        max_error = 0.
        for iteration in range(10):
            session = c.c_void_p()
            status = bridge.zyren_ml_open(runtime.OrtGetApiBase(), model, len(model)-1,
                                          c.byref(session), error, len(error))
            assert status == 0, error.value.decode()
            try:
                arrays = [np.asarray(v["values"], dtype=np.float32).reshape(v["shape"])
                          for v in values["inputs"].values()]
                dimensions = [(c.c_int64 * a.ndim)(*a.shape) for a in arrays]
                tensors = (Tensor * len(arrays))(*[
                    Tensor(1, a.ndim, d, a.nbytes, a.ctypes.data) for a, d in zip(arrays, dimensions)])
                input_names = (c.c_char_p * len(arrays))(*[x.encode() for x in values["inputs"]])
                output_names = (c.c_char_p * len(values["outputs"]))(*[x.encode() for x in values["outputs"]])
                result = c.c_void_p()
                assert bridge.zyren_ml_run(session, input_names, tensors, len(arrays),
                    output_names, len(output_names), c.byref(result), error, len(error)) == 0, error.value.decode()
                try:
                    for index, expected in enumerate(values["outputs"].values()):
                        tensor = Tensor()
                        assert bridge.zyren_ml_result_tensor(result, index, c.byref(tensor), error, len(error)) == 0
                        shape = [tensor.dimensions[i] for i in range(tensor.rank)]
                        assert shape == expected["shape"]
                        actual = np.ctypeslib.as_array(c.cast(tensor.data, c.POINTER(c.c_float)),
                                                     shape=(tensor.byte_length//4,)).copy()
                        np.testing.assert_allclose(actual, expected["values"], atol=1e-5, rtol=1e-4)
                        max_error = max(max_error, float(np.max(np.abs(actual - expected["values"]))))
                finally:
                    bridge.zyren_ml_result_close(result)
                # Byte/shape mismatch must fail without leaking a result handle.
                tensors[0].byte_length += 4
                bad = c.c_void_p()
                assert bridge.zyren_ml_run(session, input_names, tensors, len(arrays),
                    output_names, len(output_names), c.byref(bad), error, len(error)) == 1
                assert not bad.value
                assert bridge.zyren_ml_live_results() == 0
            finally:
                bridge.zyren_ml_close(session)
            assert bridge.zyren_ml_live_sessions() == 0
        receipts.append({"model": name, "loadRunCloseCycles": 10, "maxAbsoluteError": max_error})
    bad = c.c_void_p()
    invalid = c.create_string_buffer(b"invalid model")
    assert bridge.zyren_ml_open(runtime.OrtGetApiBase(), invalid, 13,
                               c.byref(bad), error, len(error)) != 0
    assert not bad.value
    assert bridge.zyren_ml_live_sessions() == bridge.zyren_ml_live_results() == 0
    return {"schemaVersion": 1, "models": receipts, "liveSessions": 0, "liveResults": 0,
            "scope": "Zyren C ABI on host CPU; Dart, mobile and accelerated provider checks remain separate."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", required=True, type=Path)
    parser.add_argument("--runtime", required=True, type=Path)
    parser.add_argument("--fixtures", required=True, type=Path)
    args = parser.parse_args()
    print(json.dumps(probe(args.bridge, args.runtime, args.fixtures), indent=2))
