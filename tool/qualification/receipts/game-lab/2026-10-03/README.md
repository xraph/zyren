# Native Game Lab diagnostic runs

These are physical-device lifecycle smoke runs, each with three seconds of
warmup and about ten seconds of measurements. Every receipt fails the sustained
qualification gates. They establish no supported capacity profile.

The Pixel 9 Pro runs use the Vulkan presenter. The macOS run uses Metal on an
Apple M3 Max. Both execute the exported guard policy and exercise camera motion,
pool activation/retirement, pause/resume and renderer recreation. Native render,
presentation, ML and physics owners return to their recorded baselines.

| Run | Learned decisions / due | Scripted ticks | Result |
| --- | --- | --- | --- |
| Android before boundary repair | 132 / 511 | 332 | Level allowed the guard to fall out of its sensor range; timing gates also failed |
| Android after boundary and fallback repair | 400 / 513 | 0 | Body observations stayed known; timing and deadline gates still failed |
| macOS before boundary repair | 126 / 508 | 374 | Native lifecycle completed; level, presentation interval and deadline issues remained |

The two Android levels have different game hashes. This is diagnostic evidence
for a behavior fix, not a controlled performance comparison. Model weights and
their evaluated 50 Hz cadence remain unchanged.

Each run retains its raw timing samples, driver log and launch metadata. The
logs use lossless gzip compression; the index pins both compressed and original
bytes, including the driver's terminal whitespace. The
latest Android run records the complete APK hash and both source snapshots.
Concurrent source changes made `inputsStable` false, so it cannot establish an
exact-source sustained qualification. The earlier launcher records the source
snapshot before building only. Its macOS executable hash does not cover the
whole application bundle. The current runner inventories complete app bundles
and rejects source changes during sustained qualification.

The earlier receipts also predate serialized admission booleans. Do not fill in
missing fields or reinterpret them as current-schema passes. The current strict
runner accepts the latest Android receipt as a diagnostic smoke result only.
Retain all failed gates when comparing later runs.
