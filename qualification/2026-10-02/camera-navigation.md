# Camera movement and cloud history

Rebuild Planet to use these fixes. They apply to the shared raycaster and cloud
history, including the Google cloud lab.

Commit `d364ad5` keeps the raycaster's geometry and scene acceleration caches
when you query through `intersectScene`. Navigation previously constructed a
new raycaster for every surface query. Globe controls can make two height
queries in one update, so a dense scene repeatedly rebuilt its triangle trees.
Distance limits, hit ordering and scene revision checks retain their behavior.

Commit `916b88d` preserves cloud history when globe controls adjust near and far
clipping. Those planes change depth mapping without changing projected XY.
Reprojection still uses the previous camera matrix and cloud ray distance.
Camera cuts, zoom, field of view, depth strategy, resize and explicit history
invalidation still reject old samples.

## Verification

The cache regression failed before the fix. Both clipping-history regressions
also failed, and the native cloud test accumulated only one frame where it
expected 18. All pass with the fixes.

The core suite passed 740 tests. The geospatial suite passed 221 with 21 optional
skips. Analysis passed for the changed source, tests and timing tool.

An AOT probe with eight dense spheres measured a median of 270.17 ms per
navigation query before cache reuse. The saved probe measured 0.007 ms after
warm-up with the fix. These are synthetic CPU measurements taken during normal
host activity. They are not city frame rates. You can run the probe from
`packages/zyren_geospatial`:

```sh
fvm dart compile exe tool/camera_navigation_cost.dart -o /tmp/zyren-camera-navigation
/tmp/zyren-camera-navigation
```

The macOS profile integration presented 48 moving frames with High clouds and
shadows over a dense ellipsoid. Every moving sample retained cloud history,
uploaded zero scene geometry bytes and used native Metal without image
readback. Portrait resize recovered its temporal history, and all checked
cleanup counters returned to zero.

Presentation intervals were 55.55 ms median and 79.901 ms at p95. They include
test harness pumping and concurrent workloads. The fixture uses procedural
clouds and no provider tiles, so it does not establish live Tokyo frame rate or
Takram parity. [Recorded samples](camera-navigation.json) retain those limits.

The final Planet widget run passed all 17 tests. An earlier run caught the
concurrent cloud-density-controls test before its widget was implemented. That
work remains outside these commits.
