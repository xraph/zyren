# Compact physics state checks

You receive the same complete `BodyState` through a smaller, versioned native
record. Both response formats read the same native values. The original map
operations remain available for independent wire and Dart decoder comparisons.

All 90 checks passed: 10 Rust, 52 physics and 28 game controller/save tests.
Scoped analysis and strict clippy passed too. The native comparison retains exact
state, event and serialized-world equality over 120 steps. Dart checks every body
kind and mass-property field against uncached legacy reads for another 120 steps.

The first test run rejected the missing operations as expected. A later fixture
comparison failed because restoring a native snapshot resets its transient mass
revision. The fixture now aligns that metadata with the live world generation;
no production revision rule or equality assertion changed. Both failures remain
in the compressed logs.

The independent source review found no open issue. This receipt establishes state
fidelity and lifecycle behavior. Device timing still needs a fresh run.
