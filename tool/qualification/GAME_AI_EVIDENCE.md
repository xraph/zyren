# Game and AI release evidence

Run `python3 tool/qualification/verify_game_ai_release.py` from the workspace root. It checks all R01-R32 requirements, all 32 tasks and the five accepted native targets. Use `--check-schema` while work is partial: explicit failed/blocked records remain valid data, but never qualify a release. Keep source and documentation evidence as repository-relative files with SHA256 pins and a description.

A passed native target needs a pinned JSON execution receipt with these fields:

```json
{"schemaVersion":1,"kind":"nativeExecution","target":"macos-metal","backend":"metal","status":"passed","skipped":false,"exitCode":0,"buildMode":"profile","physicalDevice":"your-recorded-device-id"}
```

Allowed build modes are debug, profile and release. Record the mode you ran. The target and backend must agree. A build receipt, missing device ID, failed execution or skipped job cannot qualify a target. Native execution records do not establish the separate performance budgets.

A passed trainedArtifact record needs a pinned JSON wrapper with schemaVersion 1, kind trainedArtifact, status passed, accepted true, and three pinned evidence maps: evaluation, models and nativeParity. Evaluation is one path/SHA256/description object referring to the existing T4 EvaluationReport. Models and nativeParity each contain guard and vehicle evidence objects.

The evaluator accepts the fixed T4 plan hash `70293bb2509acec9f3626a87423f5a077d496e75cad3dc734f6fff853af763c4` and audited worker revision `deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd`. The revision changes the executable pin and records its lineage; cases, seeds, targets, paired worlds, training splits and native library pins are unchanged. It recomputes all requested episode metrics and uses the shared training qualification gate. Each family needs at least 200 completed episodes and 20 held-out seeds. Guard success must reach 0.90 with a lower 95% confidence bound of 0.85. Vehicle success must reach 0.95 with a lower bound of 0.90 and collision rate at most 0.02. Leakage, reward exploits, invalid actions, missing stress coverage or worker failures reject acceptance. Receipt authors cannot lower those thresholds.

The report must use the recorded python-onnxruntime-1.23.2-cpu or native-onnxruntime-1.23.2-cpu provider, and its family_model_hashes must match the exact pinned model files. Torch and scripted evaluation do not establish exported-model quality. Unknown evaluation plans, including a future visual policy plan, remain blocked until a fixed gate is registered.

Each nativeParity pin refers to the existing T5 parity receipt: schema_version 1, status passed, provider native-onnxruntime-1.23.2-cpu, matching model_sha256, steps and typed_controller_steps both 1000, completed_runs 1000, and zero live_sessions/live_results. Keep the input sequence, frozen native worker and native library hashes in that receipt.

The receipt pins tensor_evidence and control_evidence beside it. Tensor data is finite little-endian F32 with shape [1000,2,278] for guard or [1000,2,259] for vehicle; side 0 is the export reference and side 1 is native output. Guard records logits22 plus hidden/cell128 each. Vehicle records action3 plus hidden/cell128 each. Paths must stay within the repository, and byte counts and SHA256 pins must match.

The verifier recomputes every value using fixed atol 0.00001 and rtol 0.0001. Maximum normalized error must be at most 1, and both recorded maxima must match the actual tensors. A large output can pass with absolute error above 0.00001 when its relative error stays within that fixed tolerance. Changed tensors, non-finite values and receipt-defined looser tolerances fail.

The typed control records must contain all 1000 ordered steps. The verifier decodes each guard branch from the recorded logits and fresh legality mask, and each vehicle control from the recorded action tensor. Native categorical choices must match the reference. Continuous controls use the same fixed comparison and valid steering/throttle/brake ranges. Deployment parity remains separate from quality evaluation and physical renderer/platform qualification.

Hashes and structured records detect changed or incomplete evidence. They do not authenticate who ran a test or prove that a device ID is true. Qualification owners still review and retain the actual execution logs and artifacts. The unit-test receipts are synthetic evaluator fixtures, never game qualification.
