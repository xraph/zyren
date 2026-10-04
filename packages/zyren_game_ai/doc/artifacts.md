# Accepted policy resources

Use `ModelArtifact.decode(bundleJson, files)` in `artifact.dart` before preparing
weights through the shared model cache. The reader owns copies of the manifest
and its eight resources. It checks exact resource hashes, observation/action
bindings, fixed rate, recurrent tensors, embedded normalization and a passing
held-out report for the ONNX SHA. The only providers accepted for deployment
are CPU ONNX Runtime 1.23.2, with a registered structured evaluation plan.

Every accepted artifact also needs its native parity receipt: at least 1,000
completed typed controller steps, exact model and native worker pins, declared
1e-5/1e-4 tolerances and zero remaining native sessions/results. This validates
receipt metadata. Native execution and its recorded parity results are separate
qualification evidence; the byte-only reader does not run a graph.

Float32 is supported. Float16 has no qualified path and is rejected. Int8 needs
QDQ calibration provenance and an embedded accepted float baseline manifest and
report. The reader preserves the embedded canonical Python bytes when hashing
that proof. It checks the same controller, schema, plan, source checkpoint and
fixed rate, and requires matching observation, action, normalization and recurrent
resources. The baseline must evaluate its own exact float model SHA.

Calibration is bounded to 1..2,000 steps and 256 source hashes. It must declare
the training partition, include the pinned training sources and match the native
parity source set. Candidate success loss is recomputed against the float report
and cannot exceed two percentage points. Passing the usual success/collision
thresholds is still required. A precision label or model pin cannot bypass this
baseline comparison.

The exact-byte int8 qualification test is optional because unaccepted trial
assets do not belong in the default application. Set `ZYREN_INT8_TRIAL` to the
proof-complete directory containing guard and vehicle subdirectories, then run
`artifact_quantization_test.dart`. Without that path, the test reports its
qualification cases as skipped. Regular codec and accepted-float tests still
reject missing parity and incomplete quantization proof.

Pipeline owns packaging, cache and offline export. This reader adds no archive,
disk cache, Python dependency or inference runtime to core Studio.
