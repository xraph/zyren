# Optional CoreML execution

CPU stays the default. You can request a CoreML probe for the exact embedded
opset-17 graph on a pinned Apple ONNX Runtime 1.23.2 binary. A successful load
alone does not enable it.

```dart
final report = await const MlProviderProbe().probe(
  model: manifest,
  resolver: resolveModel,
  inputs: inputs,
  referenceOutputs: independentlyComputedOutputs,
  provider: 'coreml',
);
final selection = report.selection;
if (selection != null) {
  final worker = MlWorker(providerSelections: {manifest.sha256: selection});
  final cache = MlModelCache(worker: worker, resolver: resolveModel);
  // Use your existing scheduler. Close it to drain and release the worker.
}
```

The reference must be independent of the provider under test. For a recurrent
model, supply 1,000 to 4,096 `MlProviderProbeStep` records with expected outputs.
The probe carries each runtime's actual hidden and cell outputs into its next
step, and `resetState` restores the supplied state inputs at episode boundaries.
It does not feed reference hidden values back into every step.

A token requires all of these checks:

- Cold, warm and sequence outputs match CPU and the independent reference,
  with absolute tolerance at most 1e-5 and relative tolerance at most 1e-4.
- ORT's bounded profile records CoreML kernels and no other execution provider.
  These are optimized kernel identities, not counts of original ONNX nodes.
- Alternating CPU/CoreML warm samples show at least a 5% improvement in both
  transfer-inclusive median and p95. Both halves must improve, and provider p95
  must be at most three times its median. The default is 64 pairs, bounded to
  32 through 128.

Tokens bind the complete manifest, model hash, exact input shapes, runtime and
current device identity. They cannot be constructed or restored from JSON.
They expire after fifteen minutes. A worker's selections are immutable, so CPU
and CoreML sessions cannot alias in its model cache. A different batch shape
needs another probe. Expired or mismatched requests fail explicitly.

The new C ABI appends CoreML with `ModelFormat=MLProgram`, `MLComputeUnits=ALL`,
dynamic input shapes allowed and subgraphs disabled. It sets
`session.disable_cpu_ep_fallback=1`. A graph that needs a CPU-assigned node fails
loading. The old `zyren_ml_open` ABI remains CPU-only, including frozen workers.
There is no persistent model cache added by this package. Probe-only ORT traces
are limited to 8 MiB and 65,536 events, read inside the worker and deleted after
native completion. Close waits for native work instead of releasing live buffers.
Qualification owns two serial workers and one model per worker. Both model
copies share a 64 MiB admission budget, so the comparative probe accepts models
of at most 32 MiB even when the manifest permits a larger CPU model. Boundary
tensor limits apply per worker; they do not measure or cap CoreML/ORT internal
allocators.

CoreML can choose CPU, GPU or Neural Engine internally. `actualProvider=coreml`
and an exclusive ORT partition do not identify that hardware;
`acceleratedHardware` remains null. Missing providers, unavailable targets,
unsupported graphs, numerical failures and slower runs produce no token.
NNAPI, CUDA, DirectML and WebGPU selection remain unsupported.

## Verified graph evidence

The macOS arm64 probe exercised the unchanged local linear, one-step LSTM,
CNN and four-MatMul fixtures. Linear and 1,000 recurrent LSTM steps matched
references with exclusive CoreML assignment, but were slower than CPU. The CNN
required CPU-assigned nodes and failed the strict load. The four-MatMul graph
matched an independent analytic A^5 reference and showed a stable round-trip
benefit. Its token exercised production load/run, shape admission, cancellation
and close while inference was pending, with zero live native owners afterward.

The accepted structured guard graph also matched 1,000 independent Python ORT
reference steps but was slower than CPU. The accepted vehicle graph required
CPU-assigned nodes and failed loading. Neither received a token. Their accepted
artifact files and CPU qualification pins remain unchanged. These checks do not
qualify GameLab capacity, CoreML hardware selection or physical Apple execution.

You can reproduce a trained graph probe without modifying its model:

```sh
../../tool/zyren_train/.venv/bin/python tool/provider_reference.py \
  --manifest ../../examples/game_lab/models/guard/model.json \
  --output /tmp/guard-coreml-reference.jsonl
fvm dart run tool/provider_probe.dart \
  ../../examples/game_lab/models/guard/model.json \
  /tmp/guard-coreml-reference.jsonl
```

Run these commands from `packages/zyren_ml`. The reference tool requires Python
ONNX Runtime 1.23.2 and creates a new output file rather than replacing a receipt.
Its generated waveform checks numerical provider behavior, not policy quality.
