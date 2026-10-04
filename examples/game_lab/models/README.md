# Reference policies

You can import `guard/` or `vehicle/` into Studio or regenerate the reference game
bundles with them. Each directory contains `bundle.json` and its eight exact
resources. Keep the files together. The manifest pins every resource by size
and SHA256, and the runtime checks those pins before loading native model code.

| Policy | ONNX bytes | SHA256 |
| --- | ---: | --- |
| Guard | 616135 | `34c738fe968a80442fdb70fc4187ff366248003384082ac8e29ef0e0470a48c0` |
| Vehicle | 604425 | `15cbd7d4f30bba4cb5e506e7308adf7d17a42c653d6564d25183545ddde82e66` |

Both are float32 recurrent actors with 128 hidden and 128 cell values per actor.
They run with ONNX Runtime 1.23.2 CPU and a 50 Hz simulation. Normalization lives
inside the actor graph. Do not apply it a second time. The exported files omit
the critic, optimizer and Python environment.

The immutable evaluation plan is
`deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd`.
Its source-artifact revision preserves the original held-out cases, seeds and
acceptance thresholds. The included ONNX evaluation reports record 200 successes
from 200 requested episodes for each family, with zero recorded collisions,
invalid actions, leakage or exploit failures. Those results cover the specified
native test scenarios. They do not establish behavior in every authored level.

Each provenance file also records 1,000 typed controller and recurrent-state
steps through the Dart native ML runtime, with explicit absolute and relative
comparison tolerances. Native model sessions and result buffers returned to zero
after that probe. The game host tests verify positive inference counts, actual
native controllers and brain checkpoint restoration using these exact hashes.

The weights were trained locally from repository-authored simulation recordings;
no downloaded model weights or third-party training dataset were used. The
`LicenseRef-Repository-Authored` provenance label records that origin. It is not
a separate public redistribution license. Native ONNX Runtime binaries retain
their own notices under `packages/zyren_ml/native`; packaging and platform
qualification are separate from these model files.
