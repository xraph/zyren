# Game and AI release evidence

Run `python3 tool/qualification/verify_game_ai_release.py` from the workspace root. It checks all R01-R32 requirements, all 32 tasks and the five accepted native targets. Use `--check-schema` while work is partial: explicit failed/blocked records remain valid data, but never qualify a release. Keep source and documentation evidence as repository-relative files with SHA256 pins and a description.

A passed native target needs a pinned JSON execution receipt with these fields:

```json
{"schemaVersion":1,"kind":"nativeExecution","target":"macos-metal","backend":"metal","status":"passed","skipped":false,"exitCode":0,"buildMode":"profile","physicalDevice":"your-recorded-device-id"}
```

Allowed build modes are debug, profile and release. Record the mode you ran. The target and backend must agree. A build receipt, missing device ID, failed execution or skipped job cannot qualify a target. Native execution records do not establish the separate performance budgets.

A passed trainedArtifact record needs a pinned JSON wrapper with schemaVersion 1, kind trainedArtifact, status passed, accepted true, and three pinned evidence maps: evaluation, models and nativeParity. Evaluation is one path/SHA256/description object referring to the existing T4 EvaluationReport. Models and nativeParity each contain guard and vehicle evidence objects.

The evaluator accepts the fixed T4 plan hash `70293bb2509acec9f3626a87423f5a077d496e75cad3dc734f6fff853af763c4` and audited worker revision `deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd`. The revision changes the executable pin and records its lineage; cases, seeds, targets, paired worlds, training splits and native library pins are unchanged. It recomputes all requested episode metrics and uses the shared training qualification gate. Each family needs at least 200 completed episodes and 20 held-out seeds. Guard success must reach 0.90 with a lower 95% confidence bound of 0.85. Vehicle success must reach 0.95 with a lower bound of 0.90 and collision rate at most 0.02. Leakage, reward exploits, invalid actions, missing stress coverage or worker failures reject acceptance. Receipt authors cannot lower those thresholds.

The report must use a python-onnxruntime or native-onnxruntime CPU provider, and its family_model_hashes must match the exact pinned model files. Torch and scripted evaluation do not establish exported-model quality. Unknown evaluation plans, including a future visual policy plan, remain blocked until a fixed gate is registered.

Each nativeParity file needs schemaVersion 1, kind modelParity, status passed, skipped false, source dart-zyren_ml, backend onnxruntime-cpu, the matching modelSha256, a positive integer sampleCount and maxAbsoluteError at most 0.00001. Record actual Dart/native outputs against the export reference. This checks deployment parity separately from the quality evaluation and from native renderer/platform qualification.

Hashes and structured records detect changed or incomplete evidence. They do not authenticate who ran a test or prove that a device ID is true. Qualification owners still review and retain the actual execution logs and artifacts. The unit-test receipts are synthetic evaluator fixtures, never game qualification.
