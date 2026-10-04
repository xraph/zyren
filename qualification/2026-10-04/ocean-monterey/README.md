# Monterey Bay native offline check

Open Monterey Bay in the unified Planet launcher. The source and datum notes are
in [the region README](../../../examples/planet/assets/ocean/monterey/README.md).
The original NOAA subsets are preserved in `source/`; their SHA-256 hashes match
the bundled manifest. `coast.png` is a native Metal capture on the M3 Max at
960x600, from the saved camera and time zero.

The region test imports four resources, closes the store and reopens it without
an asset loader or network transport. Terrain rendering and physical water
queries then use the restored D3 manifest. A water query succeeds at the saved
origin; a land query reports outside coverage. Both native allocation and graph
counts return to zero after disposal.

The CPU checks verify all 6,912 height conversions, bathymetry signs, wet and dry
coverage, outside-region results, manifest identity and byte-identical restart.
An altered input grid fails publication and remains unavailable offline.

The existing six scenes still render and release their resources. Their 72
canonical query samples retain the same admission policy. Eleven native/Dart
checks and 19 responsive launcher, panel and resolution checks pass.

This is a bounded geographic region with a constant regional water level, coarse
terrain and a derived land mask. It does not provide global coastline data,
tidal water levels, navigation charts or photorealistic land imagery. Mobile
verification of this added scene is recorded separately with the final install.
