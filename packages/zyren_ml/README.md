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

## Scheduled inference

Use `MlScheduler` when your calling isolate also drives a UI or render loop. Its
worker owns native session handles in a dedicated isolate. You supply the model
resolver and current simulation tick, with no scene-engine dependency.

```dart
final cache = MlModelCache(
  resolver: (path) => File('test/fixtures/$path').readAsBytes(),
);
var tick = 42;
final scheduler = MlScheduler(cache: cache, currentTick: () => tick);
try {
  final outcome = await scheduler.submit(MlRequest(
    id: 'actor-7/tick-42',
    model: manifest,
    modelHash: manifest.sha256,
    actorToken: 'episode-3/actor-7/generation-1',
    observationTick: tick,
    applicationTick: tick + 1,
    deadlineTick: tick + 1,
    tensors: {'observation': MlTensor.float32([1, 4], [1, 2, 3, 4])},
  ));
  if (outcome.status == MlOutcomeStatus.ok) {
    print(outcome.tensors['action']!.float32Values);
  }
} finally {
  await scheduler.close();
}
```

Each scheduled actor occupies one input row. The scheduler batches compatible
manifest pins and shapes, including every recurrent tensor. `MlBatchMap` keeps
request IDs and original native row indices, so cancelling a middle actor cannot
move another actor's output into its place. Actor tokens stay on the host. Check
that token and the model/tick metadata against your current episode before
applying an outcome.

Defaults are 64 queued requests, 32 MiB of queued tensor payload, 64 batch slots,
eight resident sessions and 64 MiB of serialized ONNX model bytes. You can lower
those limits. One batch runs at a time by default; a worker's native command loop
remains serial even if you raise the scheduler's bounded dispatch count. Pending
worker commands and transferred input bytes are also bounded. The default batch
wait is two milliseconds, configured up to 100 milliseconds. It uses the host
event loop, so host stalls can delay the timer; diagnostics record actual queue
time and late results are rejected against your deadline tick and wall clock.

`MlModelCache.acquire/release` manages native-session leases and in-flight
references. It does not retain source model bytes or create a disk cache. The
cache uses an exact encoded manifest pin for each model hash and rejects a
conflicting duplicate pin. An oversized new model fails before any current
session is evicted. Eviction needs both lease and in-flight counts to reach zero.

For several bundles that each name their weights `actor.onnx`, supply
`manifestResolver` instead of `resolver`. The callback receives the complete
manifest, so you can select the bundle by `manifest.sha256`. Supply exactly one
resolver. The cache copies the returned bytes and checks their hash before it
loads a session, regardless of which resolver you use.

`cancel(id)` removes a queued request or suppresses an in-flight result. Closing
joins active native work before releasing sessions and transfer buffers. It does
not kill an isolate while ORT is using its buffers. An unresponsive native call
therefore delays close; there is no unsafe forced-release timeout.

Low-level `MlSession.run` still executes synchronously on its owner isolate.
Deadlines are checked before native preparation, immediately before the call and
before outputs are accepted. Cancellation cannot interrupt ORT. The scheduled
API performs shape admission on the host and validates finite values inside the
worker, keeping large numerical scans off the UI isolate. Host tensor packing
and transfer still cost time; this is not a Flutter frame-budget qualification.

`MlProviderProbe` loads and runs the exact graph twice through a worker. You get
CPU load/cold/warm timings and, when you provide reference outputs, a numerical
parity result. CoreML and other accelerated providers fail explicitly until
qualified. A failed probe reports unknown unsupported-operator information as
null, and a successful load reports an empty list. CPU selection is explicit.

The byte limits cover model assets and boundary tensors. They do not cap ONNX
Runtime's internal allocator or execution time. Native arenas, recurrent state
and sensor storage have separate nullable diagnostic fields. Native live-handle
and run counters are process-wide; resident-model counts belong to each worker.
The supplied models are local deterministic probes, not trained policies.

## Native packaging and qualification

The build hook downloads an official runtime archive or uses the matching
archive under `native/vendor`. It checks SHA256 against
`native/runtime-manifest.json`, extracts the verified bytes and builds the C++17
shim with `native_toolchain_c`. Both libraries are bundled as native code assets;
you do not need a system ONNX installation. The shim calls the official C API
through the bundled runtime's `OrtGetApiBase`, without an ORT linker dependency.
Keep the runtime license and third-party notices with redistributed libraries.

The manifest pins desktop archives, the official Android Maven AAR and the
Apple XCFramework inside Microsoft's NuGet package, all at version 1.23.2.
Android selects the AAR's arm64, arm, x64 or x86 native library and requires
API 24. Apple selects the device arm64 or simulator arm64/x64 static archive and
links it into a bundled runtime dylib. You need an iOS 16 deployment target,
since the archive requires 15.1 and the hook's deployment setting uses integers.
The shim uses a static C++ standard library on Android, so it does not introduce
a separate shared C++ runtime dependency. Both Android assets support 16 KiB pages.

Flutter 3.47.5 currently sends a fixed native-hook iOS minimum of 15 even when your
Runner targets 16. Declare the real deployment floor explicitly in your workspace
pubspec and set the Runner's deployment target to the same value. The hook
validates this declaration and compiles both Apple libraries with it:

```yaml
hooks:
  user_defines:
    zyren_ml:
      ios_deployment_target: 16
```

A missing declaration fails when the hook receives 15. Values below 16, noninteger
values and declarations that lower the hook's target also fail. The declaration
does not change your Xcode project's deployment setting for you.

macOS arm64 CPU is verified here. Other desktop targets still need Q4 build and
device tests. Android arm64 CPU passed the 1,032-run probe on a physical Pixel 9 Pro
running Android 17. The Apple arm64 simulator passed the same probe, and an unsigned iOS
arm64 app build passed. Physical Apple execution is still blocked by the team's
weekly App ID quota. Other Android ABIs and Apple x64 simulator have crossbuild
evidence only. The [mobile probe](example/README.md) keeps execution distinct from
packaging. Apple builds require macOS; Android builds require the Android NDK. Other cross-OS builds fail explicitly. NNAPI,
CoreML and GPU execution providers are not enabled.

```sh
fvm dart analyze
fvm dart test --concurrency=1
fvm dart run tool/native_probe.dart
fvm dart run tool/scheduler_probe.dart
```

The test suite compares linear and CNN outputs against PyTorch and carries LSTM
state through 1,000 reference steps, including a reset halfway through. It also
checks integer/boolean batches, rejection paths and repeated cleanup. A native four-MatMul stress graph verifies cancellation
and disposal only after the ORT active-run counter confirms compute is running.
Timer callbacks remain responsive on the calling isolate. The probes print
native handle counts, process RSS and separate queue/load/run times. Exact native allocation and GPU
residency remain unknown, represented as null.
