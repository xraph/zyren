"""Export reproducible inference fixtures; these are not trained game policies."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn


class RecurrentProbe(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.cell = nn.LSTMCell(4, 8)
        self.head = nn.Linear(8, 2)

    def forward(self, observation, hidden, cell):
        next_hidden, next_cell = self.cell(observation, (hidden, cell))
        return torch.tanh(self.head(next_hidden)), next_hidden, next_cell


class CameraProbe(nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Conv2d(3, 4, kernel_size=3, stride=2),
            nn.ReLU(),
            nn.AdaptiveAvgPool2d((1, 1)),
            nn.Flatten(),
        )
        self.head = nn.Linear(4, 2)

    def forward(self, image):
        return torch.tanh(self.head(self.encoder(image)))


def tensor_spec(name: str, value: torch.Tensor) -> dict:
    shape = list(value.shape)
    return {"name": name, "dtype": "float32", "shape": [-1, *shape[1:]],
            "maxShape": [64, *shape[1:]]}


def export_probe(output: Path) -> dict:
    output.mkdir(parents=True, exist_ok=True)
    torch.manual_seed(7)
    torch.set_num_threads(1)
    linear = nn.Linear(4, 2).eval()
    with torch.no_grad():
        linear.weight.copy_(torch.tensor([[1., 2., 3., 4.], [-1., 0., 1., 0.]]))
        linear.bias.copy_(torch.tensor([.5, -.5]))
    cases = [
        ("linear", linear, (torch.tensor([[1., 2., 3., 4.]]),),
         ["observation"], ["action"]),
        ("lstm_step", RecurrentProbe().eval(),
         (torch.tensor([[.2, -.1, .4, .7]]), torch.zeros(1, 8), torch.zeros(1, 8)),
         ["observation", "hidden", "cell"], ["action", "next_hidden", "next_cell"]),
        ("cnn_step", CameraProbe().eval(),
         (torch.linspace(0., 1., 3 * 84 * 84).reshape(1, 3, 84, 84),),
         ["image"], ["action"]),
    ]
    results = []
    for name, model, inputs, input_names, output_names in cases:
        path = output / f"{name}.onnx"
        torch.onnx.export(
            model, inputs, str(path), input_names=input_names,
            output_names=output_names, opset_version=17, dynamo=False,
            external_data=False,
            dynamic_axes={key: {0: "batch"} for key in input_names + output_names},
        )
        onnx.checker.check_model(onnx.load(path), full_check=True)
        session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        with torch.no_grad():
            expected = model(*inputs)
        expected = expected if isinstance(expected, tuple) else (expected,)
        actual = session.run(output_names, dict(zip(input_names, (x.numpy() for x in inputs))))
        max_error = 0.0
        for native, reference in zip(actual, expected):
            np.testing.assert_allclose(native, reference.numpy(), atol=1e-5, rtol=1e-4)
            max_error = max(max_error, float(np.max(np.abs(native - reference.numpy()))))
        manifest = {
            "schemaVersion": 1, "id": name, "modelFile": path.name,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "opset": 17, "runtimeVersion": ort.__version__,
            "providers": ["cpu"], "maxModelBytes": 8 * 1024 * 1024,
            "inputs": [tensor_spec(key, value) for key, value in zip(input_names, inputs)],
            "outputs": [tensor_spec(key, value) for key, value in zip(output_names, expected)],
            "recurrent": ({"hidden": "next_hidden", "cell": "next_cell"}
                          if name == "lstm_step" else {}),
            "provenance": "Locally generated deterministic probe, seed 7; no pretrained weights.",
        }
        (output / f"{name}.json").write_text(json.dumps(manifest, indent=2) + "\n")
        fixture = {
            "inputs": {key: {"shape": list(value.shape), "values": value.flatten().tolist()}
                       for key, value in zip(input_names, inputs)},
            "outputs": {key: {"shape": list(value.shape), "values": value.flatten().tolist()}
                        for key, value in zip(output_names, expected)},
        }
        (output / f"{name}.values.json").write_text(json.dumps(fixture, separators=(",", ":")) + "\n")
        sequence = []
        # Carry state across a complete sequence, including an explicit episode reset.
        if name == "lstm_step":
            py_hidden = torch.zeros(1, 8)
            py_cell = torch.zeros(1, 8)
            native_hidden = py_hidden.numpy().copy()
            native_cell = py_cell.numpy().copy()
            for step in range(1000):
                if step == 500:
                    py_hidden.zero_(); py_cell.zero_()
                    native_hidden.fill(0); native_cell.fill(0)
                observation = torch.tensor([[np.sin(step * .1), .2, -.3, .4]], dtype=torch.float32)
                with torch.no_grad():
                    action, py_hidden, py_cell = model(observation, py_hidden, py_cell)
                native_action, native_hidden, native_cell = session.run(output_names, {
                    "observation": observation.numpy(), "hidden": native_hidden, "cell": native_cell,
                })
                for lhs, rhs in [(native_action, action.numpy()), (native_hidden, py_hidden.numpy()),
                                 (native_cell, py_cell.numpy())]:
                    np.testing.assert_allclose(lhs, rhs, atol=1e-5, rtol=1e-4)
                sequence.append({"reset": step == 500,
                    "observation": observation.flatten().tolist(),
                    "outputs": {"action": action.flatten().tolist(),
                        "next_hidden": py_hidden.flatten().tolist(),
                        "next_cell": py_cell.flatten().tolist()}})
            (output / "lstm_sequence.values.json").write_text(json.dumps(sequence, separators=(",", ":")) + "\n")
        results.append({"model": name, "sha256": manifest["sha256"],
                        "maxAbsoluteError": max_error, "bytes": path.stat().st_size,
                        "recurrentSteps": 1000 if name == "lstm_step" else 0})
    # Native byte ownership and dtype probes do not need trained weights.
    from onnx import helper, TensorProto
    dtype_inputs = [helper.make_tensor_value_info("ids", TensorProto.INT64, ["batch", 2]),
                    helper.make_tensor_value_info("mask", TensorProto.BOOL, ["batch", 2])]
    dtype_outputs = [helper.make_tensor_value_info("next_ids", TensorProto.INT64, ["batch", 2]),
                     helper.make_tensor_value_info("next_mask", TensorProto.BOOL, ["batch", 2])]
    graph = helper.make_graph([helper.make_node("Identity", ["ids"], ["next_ids"]),
                              helper.make_node("Identity", ["mask"], ["next_mask"])],
                             "typed_identity", dtype_inputs, dtype_outputs)
    typed = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)], ir_version=8)
    onnx.checker.check_model(typed, full_check=True)
    typed_path = output / "typed_identity.onnx"
    onnx.save(typed, typed_path)
    def typed_spec(name, dtype):
        return {"name": name, "dtype": dtype, "shape": [-1, 2], "maxShape": [64, 2]}
    typed_manifest = {"schemaVersion": 1, "id": "typed_identity", "modelFile": typed_path.name,
        "sha256": hashlib.sha256(typed_path.read_bytes()).hexdigest(), "opset": 17,
        "runtimeVersion": ort.__version__, "providers": ["cpu"], "maxModelBytes": 8388608,
        "inputs": [typed_spec("ids", "int64"), typed_spec("mask", "bool")],
        "outputs": [typed_spec("next_ids", "int64"), typed_spec("next_mask", "bool")],
        "recurrent": {}, "provenance": "Locally generated ONNX Identity graph; no trained weights."}
    (output / "typed_identity.json").write_text(json.dumps(typed_manifest, indent=2) + "\n")
    receipt = {"schemaVersion": 1, "torch": torch.__version__, "onnx": onnx.__version__,
               "onnxruntime": ort.__version__, "opset": 17, "seed": 7,
               "provider": "CPUExecutionProvider", "models": results,
               "scope": "Python ONNX export/inference probe; Dart native bridge verified separately."}
    (output / "export-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=Path("../../packages/zyren_ml/test/fixtures"))
    args = parser.parse_args()
    print(json.dumps(export_probe(args.output), indent=2))
