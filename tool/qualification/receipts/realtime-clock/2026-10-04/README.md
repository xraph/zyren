# Native timer precision

You can run the fixed game clock without repeated early timer wakeups. Positive
waits round up to milliseconds, while the measurement keeps the ideal deadline.
Catch-up still yields through zero-delay callbacks.

The local Dart VM truncates Duration to milliseconds before creating a timer.
The regression models its wall-clock rounding with a separate stopwatch origin,
800 microseconds of game work and 50 microseconds of event dispatch. Before the
repair, 100 simulation steps at 50 Hz needed 800 callbacks; 120 steps at 60 Hz
needed 1,040. Each case now needs one callback per step. Worker replies still
arrive before the next step, and the clock reports the quantization as lateness.

Six clock tests and 12 session tests passed. Scoped analysis and independent
source review passed. The receipt pins the SDK timer source used to construct
the model and retains the original failures. Device performance remains unverified.
