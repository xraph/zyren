# Zyren training export probe

You can reproduce the local linear, LSTMCell and 84x84 CNN exports with Python
3.11 or 3.12 and uv. No pretrained models are downloaded.

```sh
uv sync --locked
uv run --locked python scripts/export_probe.py \
  --output ../../packages/zyren_ml/test/fixtures
```

Run these commands from `tool/zyren_train`. The lock pins PyTorch 2.8.0, ONNX
1.19.1, ONNX Runtime 1.23.2 and NumPy 2.3.4. The exporter uses the explicit
TorchScript path (`dynamo=False`) with opset 17 and embedded tensor data. PyTorch
prints a deprecation notice for that exporter; the pin and export receipt keep
this probe reproducible while the newer exporter is evaluated separately.

You get model manifests, known inputs/outputs, a 1,000-step recurrent reference
sequence and `export-receipt.json`. The LSTM sequence varies observations and
resets state at step 500. A small ONNX Identity graph also exercises native int64
and bool storage. These fixtures establish export and inference feasibility.
They do not establish learned game behavior or rendered visual-policy quality.

After the Dart build hook has bundled the host runtime and bridge, you can check
the C ABI directly:

```sh
uv run --locked python scripts/native_probe.py \
  --bridge ../../.dart_tool/lib/libzyren_ml.dylib \
  --runtime ../../.dart_tool/lib/libonnxruntime.dylib \
  --fixtures ../../packages/zyren_ml/test/fixtures
```

Those library names are for macOS. The probe performs ten load/run/close cycles
for each exported model, checks a malformed tensor and confirms that no session
or result handles remain live. T1 extends this Python project with the training
environment and CLI. T5 extends the export/parity checks.
