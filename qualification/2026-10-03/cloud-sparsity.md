# Cloud sparsity

You can reduce cloud coverage with the Planet lab's Sparsity slider. Zero keeps
the selected location's coverage; 100% clears its cloud layers and shadows.
Density settings, haze and animation controls stay independent. Your sparsity
choice survives location and quality changes within the running scene.

Verification used Flutter 3.47.5 on macOS Metal:

- Geospatial package: 230 tests passed, with 21 source-asset checks skipped.
  Focused native checks also passed after the final test edits. They cover fewer
  occupied weather samples, clear cloud layers and restored ground lighting at
  full sparsity, parameter validation and refinement after a change.
- Planet: 18 widget tests passed. The cloud controls were also rendered and
  inspected at 1000 and 390 logical pixels wide.
- Static analysis passed for the changed libraries and tests.
- The native profile integration test passed at both widths with the upstream
  cloud maps and 64 MiB of simulated tile resource pressure. Its
  [recorded samples](cloud-sparsity.json) show density and animation state staying
  intact through sparsity, quality and location changes. Presentations used the
  native view with no readback. Cleanup diagnostics returned zero live sessions,
  renderers and held drawables.

The first integration attempt exceeded its resource budget before reaching the
controls. The fixture now uses the same device budget as the Google lab; the
rerun passed. The application budget did not change.

To repeat the native check from `examples/planet`:

```sh
fvm flutter drive -d macos --profile --driver=test_driver/integration_test.dart --target=integration_test/cloud_controls_test.dart
```

This run did not load Google tiles or measure navigation FPS. Android and iOS
were not exercised for this change.
