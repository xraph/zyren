# Zyren ML

You can run a versioned ONNX model on the CPU without importing Flutter or the
Zyren scene engine. Your host supplies the model bytes. The package owns native
sessions and copies tensor storage at the Dart boundary.

```dart
import 'dart:io';
import 'package:zyren_ml/zyren_ml.dart';

final manifest = MlModelManifest.decode(
  await File('test/fixtures/linear.json').readAsString(),
);
const runtime = MlRuntime();
final session = await runtime.load(
  manifest,
  (path) => File('test/fixtures/$path').readAsBytes(),
);
try {
  final result = await session.run(
    {'observation': MlTensor.float32([1, 4], [1, 2, 3, 4])},
    const MlRunOptions(requestId: 'example'),
  );
  if (result.status != MlRunStatus.ok) {
    throw StateError(result.message ?? result.status.name);
  }
  print(result.tensors['action']!.float32Values); // [30.5, 1.5]
} finally {
  await session.close();
}
```

Run this example from the package directory. In an app, you supply an asset
resolver with the workspace permissions and cache policy your host already uses.
The model file must be a relative bundle path. Hashes establish byte identity;
they do not establish publisher trust.

## Model contract

The current runtime pin is ONNX Runtime 1.23.2, C API 23, standard ONNX opset 17
and the CPU provider. You get float32, int64 and bool tensors, with at most eight
dimensions, 64 inputs and 64 outputs. Each input/output set has a 64 MiB maximum,
and the manifest can lower the 64 MiB model limit. A `-1` dimension needs a
positive `maxShape` bound. Dynamic first dimensions share a batch size.

You must name every input, including recurrent hidden and cell state. The
`recurrent` map connects each state input to its output with matching dtype,
shape and bounds. State lives in your actor/episode owner. One session accepts a
compatible actor batch and shares its immutable weights across those rows.

Before native loading, we check the model hash, actual opset, tensor interface,
operator domains and external-data declarations, including nested graphs and
constant tensors. Custom domains and custom operator libraries are unsupported.
External tensor data is also unsupported in A1; embed it in the ONNX file.
Traversal and absolute external paths fail validation. Preprocessing metadata
round-trips in the manifest, but you apply those transforms before creating
tensors. The runtime does not normalize inputs for you.

`MlSession.run` returns ok, invalid, unsupported, unavailable, cancelled or failed.
It rejects missing inputs, mismatched bounds and nonfinite floats, then checks
the outputs before exposing copied bytes. Closing a session is idempotent. A
native finalizer also releases an abandoned session, but you should close it
explicitly so cleanup has a known time.

## Scheduling limits

Inference runs synchronously on the calling isolate in A1. The returned Future
does not move ORT work to another isolate. Deadlines and cancellation are checked
before execution and before outputs are accepted; they cannot interrupt a native
call already in progress. A2 owns worker scheduling and bounded queues. You
should account for this when choosing an inference interval on a UI isolate.

The byte limits validate model assets and boundary tensors. They do not cap
ONNX Runtime's internal allocator or execution time. The supplied models are
local deterministic probes, not trained policies.

## Native packaging and qualification

The build hook downloads an official runtime archive or uses the matching
archive under `native/vendor`. It checks SHA256 against
`native/runtime-manifest.json`, extracts the verified bytes and builds the C++17
shim with `native_toolchain_c`. Both libraries are bundled as native code assets;
you do not need a system ONNX installation. The shim calls the official C API
through the bundled runtime's `OrtGetApiBase`, without an ORT linker dependency.
Keep the runtime license and third-party notices with redistributed libraries.

macOS arm64 CPU is verified here. The manifest also pins macOS x64, Linux
x64/arm64 and Windows x64/arm64 archives, but those targets still need Q4 build
and device tests. Cross-OS builds fail explicitly. Android and iOS builds fail
with a missing-runtime message until a mobile artifact and packaging process are
qualified. GPU providers are not enabled.

```sh
fvm dart analyze
fvm dart test --concurrency=1
fvm dart run tool/native_probe.dart
```

The test suite compares linear and CNN outputs against PyTorch and carries LSTM
state through 1,000 reference steps, including a reset halfway through. It also
checks integer/boolean batches, rejection paths and repeated cleanup. The probe
prints native handle counts and process RSS. Exact native allocation and GPU
residency remain unknown, represented as null.
