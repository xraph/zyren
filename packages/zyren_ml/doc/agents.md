# Optional model diagnostics

Import `package:zyren_ml/agents.dart` in a developer host that already owns an
`AgentRegistry`. The main inference library remains independent of scene imports.
Register `MlAgentProvider` with your scheduler, up to eight known model manifests
and the host's current revision callback. Keep the returned registration in the
existing scoped provider lifecycle.

The `inspect` tool requires `ml.read`. It reports model IDs, hashes, providers,
ONNX/runtime pins and bounded queue/cache counters. Native arena usage remains
null because this runtime does not report it. Inspect does not load weights or
execute inference.

You can optionally supply a host `selectModel` command. This adds a mutating
`select_model` tool under `ml.control`; the registry requires a current revision
and retry key. The adapter accepts only a registered model ID. Your host command
must recheck cancellation, revision and its own authority immediately before
committing. The tool cannot supply asset paths, bytes or credentials.

Use the existing Devtools agent bridge, job handling and CLI/MCP transport. This
adapter adds no server and no model service. Production inference uses neither.
