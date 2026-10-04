# Native ray batching checks

You can batch up to 256 rays through the existing physics query API. Ray sensors
use it when their material rules resolve the first hit. Transparent profiles
retain sequential traversal and the same per-ray query budget.

The final checks passed: 23 physics tests, 18 perception tests and eight Rust
tests. Both scoped Dart analyses and strict Rust clippy passed. Native tests
cover ordered misses, distance normalization, body and layer exclusions,
collision events, stale handles, unloaded geometry and transparent traversal.

The first native run exposed an existing solid-ray failure at a sphere's exact
centre. Its undefined normal now returns zero with the zero-distance hit. The
receipt retains that failed run and the passing regression.

The source pins were captured after testing in a shared checkout. Concurrent
mass-property and wake changes were present during the native checks and remain
owned by their author. These checks do not establish Android speed or sustained
capacity. See `receipt.json` for log hashes and source pins.
