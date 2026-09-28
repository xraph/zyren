# Offline terrain streaming

Build the first terrain slice from the remaining delivery order. You can fly
over a deterministic terrain patch with checker imagery and watch its detail
change without credentials or a network connection.

Use public core meshes and textures. Keep tile vertices relative to their
double-precision ECEF origin, then let the core subtract the camera origin.
The source contract owns metadata, cancellation and decoding. The scheduler
owns selection, bounded requests, parent fallback and cache admission.

## Task 1: Sources and bounded selection

- Define immutable tile metadata, content sizes, cancellation and source identity.
- Test perspective/orthographic screen error, frustum rejection, hysteresis,
  stable priority, ancestor fallback, byte reservations, cancellation, stale
  completions, source replacement, bounded explicit retries and LRU eviction.
- Implement a deterministic height/checker source with shared edge samples,
  skirts, local vertices and explicit top-left imagery mapping.
- Check decoded payload sizes and coordinate precision, then commit.

## Task 2: Native terrain consumer

- Add a terrain plugin with transactional scene replacement and detach cleanup.
- Add a compact terrain lab with overview/detail cameras and loading status.
- Exercise camera flights, failures/retry, resize and disposal on macOS Metal.
- Measure local vertex precision and native imagery coverage. Keep device and
  performance claims limited to the checks actually run.

## Task 3: Review and evidence

- Run affected package checks, analyzer, boundary checks and the native fixture.
- Review the complete change, fix material findings and record verification.
- Update the parity matrix and roadmap, then commit the checked result.

## Scope ruling

This is the offline streaming slice of the broader geospatial plan's task 2.
Planetary reversed depth, measured horizon depth error, remote terrain formats,
3D Tiles and provider authentication remain separate follow-on work. Standard
depth is sufficient for this bounded patch, but does not qualify planetary
surface-to-orbit depth precision. GPU budgets here cover logical geometry and
texture payloads; driver overhead and frames awaiting retirement are measured
separately by the core.
