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
