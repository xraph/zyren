# Realtime simulation clock checks

The fixed game clock now runs independently of presentation in an active native
viewport. Catch-up advances one tick per timer callback so asynchronous model
replies can settle between ticks. Rendering does not admit the same elapsed time
again. Pause, visibility loss, restore, failure and disposal stop the owner.

You can inspect the six compressed logs and their byte pins in `receipt.json`.
All 81 focused checks passed. They cover fixed-clock admission, delayed model
replies, bounded catch-up, native Rapier stepping, Studio stepping and checkpoint
controls, Flutter viewport lifecycle, benchmark accounting and receipt validation.
Scoped analysis and independent source review also passed.

The viewport tests include listener failure isolation, reentrant close and renderer
recovery while old resources are still retiring. They establish lifecycle behavior.
They do not establish timer deadlines or physical-device performance. Native
physics tests use the real physics library and a renderer test double.

Device runs must separately record clock wake lateness, pending catch-up steps,
advanced steps and discarded time. Sustained admission requires complete timing
coverage and no discarded simulation time. No model weights, cadence, deadline
or acceptance threshold changed in this slice.
