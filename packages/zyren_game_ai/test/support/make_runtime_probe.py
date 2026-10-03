"""Build the deterministic native-runtime fixture. This is not a trained policy."""
import hashlib
import json
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

root = Path(__file__).resolve().parents[1] / "fixtures"
logits = np.zeros((1, 22), np.float32)
logits[0, [2, 9, 12, 16, 18, 20]] = 10
weights = np.zeros((14, 22), np.float32)
inputs = [helper.make_tensor_value_info(n, TensorProto.FLOAT, ["batch", w])
          for n, w in [("observation", 14), ("hidden", 2)]]
outputs = [helper.make_tensor_value_info(n, TensorProto.FLOAT, ["batch", w])
           for n, w in [("logits", 22), ("next_hidden", 2)]]
graph = helper.make_graph([
    helper.make_node("MatMul", ["observation", "weights"], ["zero"]),
    helper.make_node("Add", ["zero", "bias"], ["logits"]),
    helper.make_node("Add", ["hidden", "one"], ["next_hidden"]),
], "runtime-probe", inputs, outputs, [
    numpy_helper.from_array(weights, "weights"),
    numpy_helper.from_array(logits, "bias"),
    numpy_helper.from_array(np.ones((1, 2), np.float32), "one"),
])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)], ir_version=9)
onnx.checker.check_model(model)
path = root / "runtime_probe.onnx"
onnx.save(model, path)
def spec(name, width):
    return {"name": name, "dtype": "float32", "shape": [-1, width], "maxShape": [64, width]}
manifest = {
    "schemaVersion": 1, "id": "runtime-probe", "modelFile": path.name,
    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "opset": 17,
    "runtimeVersion": "1.23.2", "providers": ["cpu"], "maxModelBytes": 1048576,
    "inputs": [spec("observation", 14), spec("hidden", 2)],
    "outputs": [spec("logits", 22), spec("next_hidden", 2)],
    "recurrent": {"hidden": "next_hidden"},
    "provenance": "Deterministic runtime test fixture. No task acceptance or training claim.",
}
(root / "runtime_probe.json").write_text(json.dumps(manifest, indent=2) + "\n")
