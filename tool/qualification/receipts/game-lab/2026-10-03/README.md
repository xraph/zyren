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
| Android with direct body queries | 349 / 510 | 0 | Perception remained the largest CPU cost; timing and deadline gates still failed |
| Android with cached immutable sensor schemas | 316 / 511 | 0 | Sensor CPU cost fell; presentation, CPU and inference deadline gates still failed |
| Android with cached collision queries and zero batching delay | 171 / 511 | 0 | Fixed-step CPU, presentation and decision deadlines still failed |
| macOS before boundary repair | 126 / 508 | 374 | Native lifecycle completed; level, presentation interval and deadline issues remained |

The Android runs include different game hashes. This is diagnostic evidence
for a behavior fix, not a controlled performance comparison. Model weights and
their evaluated 50 Hz cadence remain unchanged.

Each run retains its raw timing samples, driver log and launch metadata. The
logs use lossless gzip compression; the index pins both compressed and original
bytes, including the driver's terminal whitespace. The
cached-schema Android run records the complete APK hash and both source snapshots.
Concurrent source changes made its `inputsStable` false, so it cannot establish an
exact-source sustained qualification. The earlier launcher records the source
snapshot before building only. Its macOS executable hash does not cover the
whole application bundle. The current runner inventories complete app bundles
and rejects source changes during sustained qualification.

The earlier receipts also predate serialized admission booleans. Do not fill in
missing fields or reinterpret them as current-schema passes. The current strict
runner accepts the latest Android receipt as a diagnostic smoke result only.
Retain all failed gates when comparing later runs.

The direct-body-query run uses the current strict runner. Its native owners
returned to baseline, no invalid or stale action was applied, and all six
lifecycle checks completed. Source changed during the run. You cannot use this
ten-second result to establish a supported capacity or an isolated comparison.

The cached-schema run passed the strict smoke verifier at its recorded commit. Sensor CPU p95 was
1,377 microseconds, and the complete fixed simulation tick p95 was 4,809
microseconds. Native frame p95 was 22,313 microseconds. All six lifecycle checks
completed with no invalid or stale actions, but 195 of 511 decisions missed their
deadline. Concurrent source changes and the short duration still prevent a
sustained qualification claim.

The runs above, except the query-cache run, predate the separate native renderer
timing and output-size coverage fields. The current verifier requires those fields and matching run
identities across repetitions. Keep the original receipts intact; their earlier
smoke verification does not establish admission under the newer checks.

The separate macOS UI receipt records native Play, checkpoint save/step/restore,
Resume, keyboard jump and loading the vehicle playground. It pins the complete
executed application bundle. The visible controls and game status appeared in
the native accessibility tree, but a spoken screen-reader pass, physical gamepad,
movement and narrow-window checks remain unverified. This receipt has no source
snapshot from before its build and cannot qualify exact-source performance.

The query-cache run passed the current strict smoke verifier with stable source
hashes before and after the build and execution. It pins the complete APK and
records all 352 presented frames at 960 by 2061 pixels. GPU time p95 was 587
microseconds, renderer build p95 was 633 microseconds, and renderer submit p95
was 679 microseconds. These narrow timings do not include the whole frame.

The complete fixed tick p95 was 4,882 microseconds, native frame p95 was 24,970
microseconds, and presenter interval p95 was 40,772 microseconds. Only 171 of
511 decisions met their tick deadline. All six lifecycle checks passed, no stale
or invalid action was applied, and native owners returned to baseline. You
cannot qualify capacity from this 10.51-second run. Its source, game and workload
pins also differ from earlier runs, so it does not isolate the effect of caching.

The realtime-clock run met 499 of 507 decision deadlines during 10.36 seconds.
It recorded 504 fixed simulation steps, 741 timer wakes and no discarded time.
Clock wake lateness p95 was 1,630 microseconds; pending catch-up steps p95 was zero.
All six lifecycle checks completed with no fallback ticks, scripted ticks,
rejected actions, invalid actions or stale applications. Native owners returned
to baseline. All 556 native output frames were 960 by 2061 pixels.

Fixed simulation CPU p95 was 4,485 microseconds, full native frame p95 was 17,334,
and presenter interval p95 was 24,275. Native preparation, encoding and completion
wait p95 were 891, 644 and 3,046 microseconds respectively; GPU p95 was 609.
Completion wait can overlap GPU execution, so these timings are not additive.
This run still fails CPU, frame, deadline and sustained-duration admission.

The strict smoke verifier passed, but source changed during the build and run.
This receipt therefore records `smokeUnstable`. Its improved deadline count does
not isolate the timer change from body-state caching or concurrent physics and
renderer work. No sustained capacity is qualified.

The preceding build attempt failed while a new artifact-reader Dart part was
being written. Its separate build-failure index identifies the retained launcher
APK as the preexisting query-cache build. No game execution or performance claim
comes from that failed attempt. The reader compiled before the successful retry.

## Android guard diagnostic after the ray API change

`android-ray-api.index.json` pins run 10, its APK, raw measurement and launch log.
All six lifecycle checks passed and owners returned to baseline. The run met
499 of 507 decision deadlines, discarded no clock time and applied no stale or
fallback actions. It still failed the sustained, frame and CPU gates.

Game/perception CPU p95 was 5.393ms, full native frame p95 was 21.967ms and
presentation p95 was 40.282ms. This was a 10.388-second diagnostic in a changing
checkout. The guard uses VisionSensor, so this run did not exercise the new
RaySensor batching path and does not establish a speed change.
