# Pixel game smoke evidence

Smoke 11 ran the accepted guard game on the physical Pixel 9 Pro with native
Vulkan presentation and ONNX Runtime CPU inference. The receipt includes vision
ray batching, combined capsule movement/target submission and millisecond timer
rounding. It is a short diagnostic run, not a qualified capacity result.

The run measured 551 frames over 10.367 seconds. There were 504 simulation steps
and 504 timer wakeups, with no discarded time or pending catch-up backlog. All
six lifecycle checks passed and native owner counts returned to baseline.
Decisions completed 499 of 507 deadlines. No stale, invalid or rejected action
was applied, and no scripted or fallback tick was measured.

At p95, game/perception CPU took 3.859 ms, full native frames took 17.514 ms and
presentation intervals took 23.885 ms. Primitive controllers took 0.685 ms,
physics 1.450 ms and sensors 0.902 ms. These subsystem percentiles are not
additive. The 2 ms game CPU and frame budgets remain unmet.

Source changed during the build/run, so these numbers do not isolate any one
change. You can check the raw samples, failed gates, native APK hash and source
hashes in the retained receipt and launch record.

## Direct physics-step follow-up

Smoke 12 includes reuse of completed native step poses when interpolation is off.
You can inspect its raw samples in `android-direct-physics-step.receipt.json`. The
physical Pixel run measured 570 frames over 10.369 seconds, with 504 simulation
steps and 504 timer wakeups. No time was discarded and no catch-up backlog remained.

At p95, game/perception CPU took 3.340 ms, physics took 0.917 ms and sensors took
0.950 ms. Full native frames measured 16.397 ms and presentation intervals measured
23.225 ms. The 2 ms game CPU and presentation budgets remain unmet. All six lifecycle
checks passed, 499 of 507 decisions met their deadline, and native owners returned
to baseline without stale, invalid, rejected, scripted or fallback actions.

The launch record retains the changed source hashes and the 78,187,099-byte APK
hash. Shared edits prevent an isolated comparison with smoke 11. Both runs are
short diagnostics; neither establishes sustained capacity.

## Dense state, shared sensors and frame diagnostics

Smoke 13 includes dense native physics state transport, reuse of matching sensor
captures within one phase, and Android frame diagnostics returned with the render
receipt. The profile APK compiled and the physical Pixel run produced 600 frames
in 10.357 seconds. You can check its APK and source hashes in
`android-dense-sensors-frame-profile.index.json`.

At p95, full native frames took 13.924 ms, presentation intervals took 21.646 ms
and game/perception CPU took 2.961 ms. Physics measured 0.575 ms, sensors 0.733 ms
and primitive controllers 0.796 ms. The presentation and game CPU budgets still
failed. There were 504 steps with no discarded time or pending backlog, and 499
of 507 decisions met their deadline. No stale, invalid, rejected, scripted or
fallback action was applied. All six lifecycle checks passed and native owners
returned to baseline.

These are short diagnostic measurements. Source changed during the build/run,
so the retained receipt cannot establish an isolated speedup or sustained capacity.
