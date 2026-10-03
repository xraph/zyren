"""Generate the small, weight-free ONNX scheduling stress fixture."""
from pathlib import Path
import hashlib
import json

import onnx
from onnx import helper, TensorProto

output = Path(__file__).resolve().parent.parent / "test" / "fixtures"
size = 1024
nodes = []
previous = "observation"
for index in range(4):
    result = "action" if index == 3 else f"product_{index}"
    nodes.append(helper.make_node("MatMul", [previous, "observation"], [result]))
    previous = result

def value_info(name):
    return helper.make_tensor_value_info(name, TensorProto.FLOAT, ["batch", size, size])

graph = helper.make_graph(nodes, "slow_matmul", [value_info("observation")], [value_info("action")])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)], ir_version=8)
onnx.checker.check_model(model, full_check=True)
path = output / "slow_matmul.onnx"
onnx.save(model, path)

def spec(name):
    return {"name": name, "dtype": "float32", "shape": [-1, size, size], "maxShape": [3, size, size]}

manifest = {"schemaVersion": 1, "id": "slow_matmul", "modelFile": path.name,
    "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "opset": 17,
    "runtimeVersion": "1.23.2", "providers": ["cpu"], "maxModelBytes": 8388608,
    "inputs": [spec("observation")], "outputs": [spec("action")], "recurrent": {},
    "provenance": "Locally generated four-MatMul scheduling stress graph, no stored weights or pretrained model."}
(output / "slow_matmul.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(json.dumps({"bytes": path.stat().st_size, "sha256": manifest["sha256"]}))
